import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { mqttPublish } from '../_shared/mqtt-publish.ts'

// Config command bytes (must match ESP32 firmware)
const CMD_RESTART = 0x30
const CMD_MDB_ADDRESS = 0x31
const CMD_MDB_RESET = 0x32

/**
 * Build a 19-byte XOR-encrypted config payload.
 * Same binary format as send-credit: cmd(1) + version(1) + param(4) + unused(2) + timestamp(4) + padding(6) + checksum(1)
 * XOR bytes [1..18] with passkey.
 */
function buildConfigPayload(cmd: number, param: number, passkey: string): Uint8Array {
  const payload = new Uint8Array(19)
  crypto.getRandomValues(payload) // fill with random (padding bytes stay random)

  const timestampSec = Math.floor(Date.now() / 1000)

  payload[0] = cmd
  payload[1] = 0x01                            // version v1
  payload[2] = (param >> 24) & 0xff            // param (big-endian u32)
  payload[3] = (param >> 16) & 0xff
  payload[4] = (param >> 8) & 0xff
  payload[5] = (param >> 0) & 0xff
  payload[6] = 0x00                            // itemNumber (unused)
  payload[7] = 0x00
  payload[8] = (timestampSec >> 24) & 0xff     // timestamp
  payload[9] = (timestampSec >> 16) & 0xff
  payload[10] = (timestampSec >> 8) & 0xff
  payload[11] = (timestampSec >> 0) & 0xff

  // Checksum: sum of bytes 0..17
  let chk = 0
  for (let i = 0; i < 18; i++) chk += payload[i]
  payload[18] = chk & 0xff

  // XOR bytes 1..18 with passkey
  const cipher = [...passkey].map((c: string) => c.charCodeAt(0))
  for (let k = 0; k < cipher.length; k++) {
    payload[k + 1] ^= cipher[k]
  }

  return payload
}

Deno.serve(async (req) => {
  try {
    const body = await req.json()
    const { device_id, config } = body

    if (!device_id || !config || typeof config !== 'object') {
      return new Response(JSON.stringify({ error: 'device_id and config are required' }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Validate config values ──────────────────────────────────────────────
    const dbUpdate: Record<string, unknown> = {}
    const configActions: { cmd: number; param: number; label: string }[] = []

    if (config.mdb_address !== undefined) {
      if (config.mdb_address !== 1 && config.mdb_address !== 2) {
        return new Response(JSON.stringify({ error: 'mdb_address must be 1 or 2' }), {
          status: 400, headers: { 'Content-Type': 'application/json' },
        })
      }
      dbUpdate.mdb_address = config.mdb_address
      configActions.push({ cmd: CMD_MDB_ADDRESS, param: config.mdb_address, label: 'mdb_address' })
    }

    // Remote restart — no DB update needed
    if (config.restart === true) {
      configActions.push({ cmd: CMD_RESTART, param: 0, label: 'restart' })
    }

    // MDB soft reset — device announces "Just Reset" on next POLL, VMC re-runs SETUP
    if (config.mdb_reset === true) {
      configActions.push({ cmd: CMD_MDB_RESET, param: 0, label: 'mdb_reset' })
    }

    if (configActions.length === 0) {
      return new Response(JSON.stringify({ error: 'No valid config keys provided' }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Authenticate caller ─────────────────────────────────────────────────
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Authorization required' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }

    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Verify admin role ───────────────────────────────────────────────────
    const { data: membership } = await adminClient
      .from('organization_members')
      .select('company_id, role')
      .eq('user_id', user.id)
      .maybeSingle()

    if (!membership || membership.role !== 'admin') {
      return new Response(JSON.stringify({ error: 'Admin role required' }), {
        status: 403, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Look up device (with passkey for XOR encryption) ────────────────────
    const { data: device, error: deviceError } = await adminClient
      .from('embeddeds')
      .select('id, company, status, passkey')
      .eq('id', device_id)
      .eq('company', membership.company_id)
      .maybeSingle()

    if (deviceError || !device) {
      return new Response(JSON.stringify({ error: 'Device not found or not in your organization' }), {
        status: 404, headers: { 'Content-Type': 'application/json' },
      })
    }

    if (!device.passkey) {
      return new Response(JSON.stringify({ error: 'Device has no passkey configured' }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Update DB (skip if only restart, no persistent config changes) ──────
    if (Object.keys(dbUpdate).length > 0) {
      const { error: updateError } = await adminClient
        .from('embeddeds')
        .update(dbUpdate)
        .eq('id', device.id)

      if (updateError) throw updateError
    }

    // ── Publish XOR-encrypted config to MQTT ────────────────────────────────
    const topic = `/${device.company}/${device.id}/config`

    // Send each config action as a separate encrypted message
    for (const action of configActions) {
      const payload = buildConfigPayload(action.cmd, action.param, device.passkey)
      await mqttPublish(topic, payload, { qos: 1 })
    }

    // ── Activity log (best-effort) ──────────────────────────────────────────
    const configSummary = Object.fromEntries(
      configActions.map(a => [a.label, a.param || true])
    )
    try {
      await adminClient.from('activity_log').insert({
        company_id: device.company,
        user_id: user.id,
        entity_type: 'device',
        entity_id: device.id,
        action: 'config_updated',
        metadata: { config: configSummary },
      })
    } catch (_) { /* best-effort */ }

    return new Response(JSON.stringify({
      status: device.status,
      config: configSummary,
    }), {
      headers: { 'Content-Type': 'application/json' },
    })

  } catch (err) {
    return new Response(JSON.stringify({ error: err?.message ?? err }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    })
  }
})
