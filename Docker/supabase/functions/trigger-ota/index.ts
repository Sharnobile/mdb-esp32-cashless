import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { mqttPublish } from '../_shared/mqtt-publish.ts'

Deno.serve(async (req) => {
  try {
    const body = await req.json();

    // ── Authenticate caller ─────────────────────────────────────────────────
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.replace('Bearer ', '')
    const companyIdHeader = req.headers.get('X-Company-Id')

    let userId: string | null = null
    let companyId: string | null = null

    // Path 1: Service-role call from API gateway (X-Company-Id present)
    if (token === serviceRoleKey && companyIdHeader) {
      companyId = companyIdHeader
    } else {
      // Path 2: Normal user JWT
      const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get('SUPABASE_ANON_KEY')!,
        { global: { headers: { Authorization: authHeader } } }
      );
      const { data: { user }, error: authError } = await supabase.auth.getUser();
      if (authError || !user) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        });
      }
      userId = user.id

      // Resolve company from user membership
      const { data: membership } = await adminClient
        .from('organization_members')
        .select('company_id')
        .eq('user_id', userId)
        .maybeSingle()
      companyId = membership?.company_id ?? null
    }

    if (!companyId) {
      return new Response(JSON.stringify({ error: 'Could not resolve company' }), {
        status: 403, headers: { 'Content-Type': 'application/json' },
      });
    }

    // Look up the target device (admin client, filtered by company)
    const { data: device, error: deviceError } = await adminClient
      .from("embeddeds")
      .select("id, company, status")
      .eq("id", body.device_id)
      .eq("company", companyId)
      .single();

    if (deviceError || !device) {
      return new Response(JSON.stringify({ error: 'Device not found' }), {
        status: 404, headers: { 'Content-Type': 'application/json' },
      });
    }

    // Look up the firmware version
    const { data: firmware, error: fwError } = await adminClient
      .from("firmware_versions")
      .select("id, file_path, version_label")
      .eq("id", body.firmware_id)
      .single();

    if (fwError || !firmware) {
      return new Response(JSON.stringify({ error: 'Firmware version not found' }), {
        status: 404, headers: { 'Content-Type': 'application/json' },
      });
    }

    // Construct the public download URL for the firmware binary
    // Use SUPABASE_PUBLIC_URL so the ESP32 device can reach it (not the internal Docker hostname)
    const publicUrl = Deno.env.get("PUBLIC_SUPABASE_URL") || Deno.env.get("SUPABASE_PUBLIC_URL") || Deno.env.get("SUPABASE_URL")!;
    const downloadUrl = `${publicUrl}/storage/v1/object/public/firmware/${firmware.file_path}`;

    // Publish OTA command to the device's MQTT topic
    const otaTopic = `/${device.company}/${device.id}/ota`;
    const payload = JSON.stringify({ url: downloadUrl });

    await mqttPublish(otaTopic, payload, { qos: 1 });

    // Record the OTA trigger in the database
    await adminClient
      .from("ota_updates")
      .insert({
        embedded_id: device.id,
        firmware_version_id: firmware.id,
        triggered_by: userId,
        status: 'triggered',
      });

    return new Response(JSON.stringify({
      status: device.status,
      firmware: firmware.version_label,
      topic: otaTopic,
    }), {
      headers: { 'Content-Type': 'application/json' },
    });

  } catch (err) {
    return new Response(JSON.stringify({ message: err?.message ?? err }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    });
  }
});
