# Alerting System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a server-side alerting system that detects operational anomalies (device offline, missing sales patterns, MDB errors, OTA failures) and sends push notifications + displays alerts in a frontend dashboard.

**Architecture:** pg_cron triggers a `check-alerts` edge function every 15 minutes. The function queries each company's devices against configurable rules, creates alert records, and dispatches push notifications via the existing `sendPushToUsers` infrastructure. A new `/alerts` page shows alert history with acknowledge/configure capabilities.

**Tech Stack:** PostgreSQL (pg_cron, pg_net), Supabase Edge Functions (Deno), Nuxt 4, shadcn-nuxt, TailwindCSS 4

---

## Task 1: Database Migration — Alert Tables

**Files:**
- Create: `Docker/supabase/migrations/20260312000000_alerts.sql`

**Step 1: Write the migration file**

```sql
-- =====================================================
-- Alerting system: tables, functions, pg_cron schedule
-- =====================================================

-- 1. alerts table (history)
CREATE TABLE IF NOT EXISTS public.alerts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at      timestamptz NOT NULL DEFAULT now(),
    company_id      uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    embedded_id     uuid REFERENCES public.embeddeds(id) ON DELETE SET NULL,
    machine_id      uuid REFERENCES public."vendingMachine"(id) ON DELETE SET NULL,
    alert_type      text NOT NULL,
    severity        text NOT NULL DEFAULT 'warning'
        CHECK (severity IN ('info', 'warning', 'critical')),
    title           text NOT NULL,
    message         text NOT NULL,
    metadata        jsonb DEFAULT '{}',
    status          text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'acknowledged', 'resolved')),
    acknowledged_at timestamptz,
    acknowledged_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    resolved_at     timestamptz
);

ALTER TABLE public.alerts ENABLE ROW LEVEL SECURITY;

GRANT SELECT, UPDATE ON public.alerts TO authenticated;
GRANT ALL ON public.alerts TO service_role;

CREATE POLICY alerts_select ON public.alerts
    FOR SELECT TO authenticated
    USING (company_id = public.my_company_id());

CREATE POLICY alerts_update ON public.alerts
    FOR UPDATE TO authenticated
    USING (company_id = public.my_company_id() AND public.i_am_admin());

CREATE INDEX idx_alerts_company_status ON public.alerts (company_id, status, created_at DESC);
CREATE INDEX idx_alerts_cooldown ON public.alerts (company_id, alert_type, embedded_id, created_at DESC);

ALTER PUBLICATION supabase_realtime ADD TABLE public.alerts;

-- 2. alert_rules table (per-company configuration)
CREATE TABLE IF NOT EXISTS public.alert_rules (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    company_id       uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    alert_type       text NOT NULL,
    enabled          boolean NOT NULL DEFAULT true,
    config           jsonb NOT NULL DEFAULT '{}',
    cooldown_minutes integer NOT NULL DEFAULT 60,
    UNIQUE (company_id, alert_type)
);

ALTER TABLE public.alert_rules ENABLE ROW LEVEL SECURITY;

GRANT SELECT, UPDATE ON public.alert_rules TO authenticated;
GRANT ALL ON public.alert_rules TO service_role;

CREATE POLICY alert_rules_select ON public.alert_rules
    FOR SELECT TO authenticated
    USING (company_id = public.my_company_id());

CREATE POLICY alert_rules_update ON public.alert_rules
    FOR UPDATE TO authenticated
    USING (company_id = public.my_company_id() AND public.i_am_admin());

-- 3. Function to seed default alert rules for a company
CREATE OR REPLACE FUNCTION public.seed_alert_rules(p_company_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.alert_rules (company_id, alert_type, enabled, config, cooldown_minutes)
    VALUES
        (p_company_id, 'device_offline',      true, '{"offline_minutes": 30}',                    60),
        (p_company_id, 'no_sales_anomaly',    true, '{"min_expected_sales": 1, "weeks_lookback": 4}', 240),
        (p_company_id, 'mdb_error',           true, '{"states": ["INACTIVE", "DISABLED"]}',       120),
        (p_company_id, 'ota_failure',         true, '{}',                                          60),
        (p_company_id, 'high_checksum_errors',true, '{"error_threshold": 50}',                    360)
    ON CONFLICT (company_id, alert_type) DO NOTHING;
END;
$$;

-- 4. Seed defaults for all existing companies
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT id FROM public.companies LOOP
        PERFORM public.seed_alert_rules(r.id);
    END LOOP;
END;
$$;

-- 5. Trigger to auto-seed alert rules when a new company is created
CREATE OR REPLACE FUNCTION public.on_company_created_seed_alerts()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    PERFORM public.seed_alert_rules(NEW.id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_company_created_seed_alerts
    AFTER INSERT ON public.companies
    FOR EACH ROW
    EXECUTE FUNCTION public.on_company_created_seed_alerts();

-- 6. Sales pattern analysis function
-- Returns avg sales count per machine for a given day-of-week + hour
CREATE OR REPLACE FUNCTION public.get_sales_pattern(
    p_machine_ids uuid[],
    p_dow integer,       -- 0=Sunday, 6=Saturday
    p_hour integer,      -- 0-23
    p_since timestamptz
)
RETURNS TABLE(machine_id uuid, avg_sales numeric)
LANGUAGE sql STABLE AS $$
    WITH weekly_counts AS (
        SELECT
            s.machine_id,
            date_trunc('week', s.created_at) AS week_start,
            count(*) AS sales_count
        FROM public.sales s
        WHERE s.machine_id = ANY(p_machine_ids)
          AND s.created_at >= p_since
          AND extract(dow FROM s.created_at) = p_dow
          AND extract(hour FROM s.created_at) = p_hour
        GROUP BY s.machine_id, date_trunc('week', s.created_at)
    )
    SELECT
        wc.machine_id,
        avg(wc.sales_count)::numeric AS avg_sales
    FROM weekly_counts wc
    GROUP BY wc.machine_id
$$;

GRANT EXECUTE ON FUNCTION public.get_sales_pattern TO service_role;

-- 7. pg_cron + pg_net for scheduled alert checks
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

GRANT USAGE ON SCHEMA cron TO postgres;

-- The cron job calls the check-alerts edge function every 15 minutes.
-- It uses pg_net to make an HTTP POST to the internal Kong gateway.
-- The webhook secret and URL are set via PGRST_APP_SETTINGS_* env vars
-- on the db container in docker-compose.yml.
SELECT cron.schedule(
    'check-alerts-job',
    '*/15 * * * *',
    $$
    SELECT net.http_post(
        url := current_setting('app.settings.supabase_url', true) || '/functions/v1/check-alerts',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'X-Webhook-Secret', current_setting('app.settings.alerts_webhook_secret', true)
        ),
        body := '{}'::jsonb
    );
    $$
);
```

**Step 2: Run migration to verify it works**

Run: `cd Docker/supabase && supabase db reset`
Expected: Migration runs without errors, `alerts` and `alert_rules` tables created, default rules seeded.

**Step 3: Commit**

```bash
git add Docker/supabase/migrations/20260312000000_alerts.sql
git commit -m "feat: add alerts and alert_rules tables with pg_cron schedule"
```

---

## Task 2: Docker Configuration for pg_cron

**Files:**
- Modify: `Docker/docker-compose.yml` (db environment section, ~line 387-404)

**Step 1: Add app.settings env vars to the db service**

Add these two environment variables to the `db:` → `environment:` block (after the existing `JWT_EXP` line):

```yaml
      # For pg_cron/pg_net to call edge functions
      PGRST_APP_SETTINGS_SUPABASE_URL: http://kong:8000
      PGRST_APP_SETTINGS_ALERTS_WEBHOOK_SECRET: ${MQTT_WEBHOOK_SECRET}
```

These become available as `current_setting('app.settings.supabase_url')` and `current_setting('app.settings.alerts_webhook_secret')` in PostgreSQL, which the pg_cron job uses to call the check-alerts edge function.

**Step 2: Commit**

```bash
git add Docker/docker-compose.yml
git commit -m "feat: add pg_cron app.settings env vars for alert scheduling"
```

---

## Task 3: Edge Function — check-alerts

**Files:**
- Create: `Docker/supabase/functions/check-alerts/index.ts`
- Create: `Docker/supabase/functions/check-alerts/deno.json`
- Modify: `Docker/supabase/config.toml` (add function entry)

**Step 1: Create deno.json**

```json
{
  "imports": {}
}
```

**Step 2: Create the check-alerts edge function**

```typescript
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { sendPushToUsers } from '../_shared/web-push.ts'

interface AlertRule {
  id: string
  alert_type: string
  enabled: boolean
  config: Record<string, unknown>
  cooldown_minutes: number
}

interface NewAlert {
  company_id: string
  embedded_id: string | null
  machine_id: string | null
  alert_type: string
  severity: string
  title: string
  message: string
  metadata: Record<string, unknown>
}

Deno.serve(async (req) => {
  try {
    // Verify webhook secret (same pattern as mqtt-webhook)
    const secret = req.headers.get('X-Webhook-Secret')
    const expectedSecret = Deno.env.get('MQTT_WEBHOOK_SECRET')
    if (!expectedSecret || secret !== expectedSecret) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 })
    }

    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    // Get all companies
    const { data: companies } = await adminClient
      .from('companies')
      .select('id')

    let totalAlerts = 0

    for (const company of companies ?? []) {
      // Get enabled alert rules for this company
      const { data: rules } = await adminClient
        .from('alert_rules')
        .select('*')
        .eq('company_id', company.id)
        .eq('enabled', true)

      if (!rules || rules.length === 0) continue

      const ruleMap = new Map((rules as AlertRule[]).map(r => [r.alert_type, r]))

      // Get all devices for this company (used by multiple checks)
      const { data: companyDevices } = await adminClient
        .from('embeddeds')
        .select('id, mac_address, status, status_at, mdb_diagnostics')
        .eq('company', company.id)

      if (!companyDevices || companyDevices.length === 0) continue

      const newAlerts: NewAlert[] = []

      // ── Check 1: Device offline ─────────────────────────────────────
      const offlineRule = ruleMap.get('device_offline')
      if (offlineRule) {
        const offlineMinutes = (offlineRule.config?.offline_minutes as number) ?? 30
        const cutoff = new Date(Date.now() - offlineMinutes * 60_000).toISOString()

        for (const device of companyDevices) {
          // Only alert if device was previously online and now silent
          if (!device.status_at || device.status === 'offline') continue
          if (device.status_at >= cutoff) continue

          if (await isInCooldown(adminClient, company.id, 'device_offline', device.id, offlineRule.cooldown_minutes)) continue

          newAlerts.push({
            company_id: company.id,
            embedded_id: device.id,
            machine_id: null,
            alert_type: 'device_offline',
            severity: 'critical',
            title: 'Device Offline',
            message: `Device ${device.mac_address ?? device.id.slice(0, 8)} has not sent a heartbeat for ${offlineMinutes}+ minutes.`,
            metadata: { last_status: device.status, last_seen: device.status_at },
          })
        }
      }

      // ── Check 2: No-sales anomaly (pattern-based) ───────────────────
      const salesRule = ruleMap.get('no_sales_anomaly')
      if (salesRule) {
        const anomalies = await checkSalesAnomalies(adminClient, company.id, companyDevices, salesRule)
        for (const a of anomalies) {
          if (await isInCooldown(adminClient, company.id, 'no_sales_anomaly', a.embedded_id, salesRule.cooldown_minutes)) continue
          newAlerts.push(a)
        }
      }

      // ── Check 3: MDB error states ──────────────────────────────────
      const mdbRule = ruleMap.get('mdb_error')
      if (mdbRule) {
        const badStates = (mdbRule.config?.states as string[]) ?? ['INACTIVE', 'DISABLED']
        const cutoff = new Date(Date.now() - 15 * 60_000).toISOString()
        const deviceIds = companyDevices.map(d => d.id)

        const { data: mdbErrors } = await adminClient
          .from('mdb_log')
          .select('embedded_id, state, prev_state, created_at')
          .in('embedded_id', deviceIds)
          .in('state', badStates)
          .gte('created_at', cutoff)

        // Group by device, alert once per device
        const seen = new Set<string>()
        for (const err of mdbErrors ?? []) {
          if (seen.has(err.embedded_id)) continue
          seen.add(err.embedded_id)

          if (await isInCooldown(adminClient, company.id, 'mdb_error', err.embedded_id, mdbRule.cooldown_minutes)) continue

          const device = companyDevices.find(d => d.id === err.embedded_id)
          newAlerts.push({
            company_id: company.id,
            embedded_id: err.embedded_id,
            machine_id: null,
            alert_type: 'mdb_error',
            severity: 'warning',
            title: 'MDB Error State',
            message: `Device ${device?.mac_address ?? err.embedded_id.slice(0, 8)} entered ${err.state} state (from ${err.prev_state ?? 'unknown'}).`,
            metadata: { state: err.state, prev_state: err.prev_state },
          })
        }
      }

      // ── Check 4: OTA failures ──────────────────────────────────────
      const otaRule = ruleMap.get('ota_failure')
      if (otaRule) {
        for (const device of companyDevices) {
          if (device.status !== 'ota_failed') continue
          if (await isInCooldown(adminClient, company.id, 'ota_failure', device.id, otaRule.cooldown_minutes)) continue

          newAlerts.push({
            company_id: company.id,
            embedded_id: device.id,
            machine_id: null,
            alert_type: 'ota_failure',
            severity: 'critical',
            title: 'OTA Update Failed',
            message: `Firmware update failed on device ${device.mac_address ?? device.id.slice(0, 8)}.`,
            metadata: {},
          })
        }
      }

      // ── Check 5: High checksum errors ──────────────────────────────
      const chkRule = ruleMap.get('high_checksum_errors')
      if (chkRule) {
        const threshold = (chkRule.config?.error_threshold as number) ?? 50
        for (const device of companyDevices) {
          const chkErr = (device.mdb_diagnostics as Record<string, unknown>)?.chkErr as number ?? 0
          if (chkErr < threshold) continue
          if (await isInCooldown(adminClient, company.id, 'high_checksum_errors', device.id, chkRule.cooldown_minutes)) continue

          newAlerts.push({
            company_id: company.id,
            embedded_id: device.id,
            machine_id: null,
            alert_type: 'high_checksum_errors',
            severity: 'warning',
            title: 'High MDB Checksum Errors',
            message: `Device ${device.mac_address ?? device.id.slice(0, 8)} has ${chkErr} checksum errors.`,
            metadata: { chk_err: chkErr },
          })
        }
      }

      // ── Insert alerts and send push notifications ──────────────────
      if (newAlerts.length > 0) {
        const { data: inserted } = await adminClient
          .from('alerts')
          .insert(newAlerts)
          .select('id, alert_type, title, message')

        totalAlerts += (inserted ?? []).length

        // Group by alert_type for notification batching
        const typeGroups = new Map<string, typeof inserted>()
        for (const alert of inserted ?? []) {
          const existing = typeGroups.get(alert.alert_type) ?? []
          existing.push(alert)
          typeGroups.set(alert.alert_type, existing)
        }

        for (const [type, alerts] of typeGroups) {
          const count = alerts!.length
          const title = count === 1
            ? alerts![0].title
            : `${count} ${type.replace(/_/g, ' ')} alerts`
          const body = count === 1
            ? alerts![0].message
            : `${count} new alerts detected.`

          try {
            await sendPushToUsers(adminClient, company.id, `alert_${type}`, {
              title,
              body,
              data: { type: 'alert', alert_type: type, count },
            })
          } catch (e) {
            console.error(`Push failed for ${type}:`, e)
          }
        }
      }
    }

    return new Response(
      JSON.stringify({ ok: true, alerts_created: totalAlerts }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    )
  } catch (err) {
    console.error('check-alerts error:', err)
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500 },
    )
  }
})

// ── Cooldown check ─────────────────────────────────────────────────────────
async function isInCooldown(
  client: ReturnType<typeof createClient>,
  companyId: string,
  alertType: string,
  embeddedId: string | null,
  cooldownMinutes: number,
): Promise<boolean> {
  const since = new Date(Date.now() - cooldownMinutes * 60_000).toISOString()
  let query = client
    .from('alerts')
    .select('id')
    .eq('company_id', companyId)
    .eq('alert_type', alertType)
    .gte('created_at', since)
    .limit(1)

  if (embeddedId) query = query.eq('embedded_id', embeddedId)

  const { data } = await query
  return (data ?? []).length > 0
}

// ── Sales anomaly detection ────────────────────────────────────────────────
async function checkSalesAnomalies(
  client: ReturnType<typeof createClient>,
  companyId: string,
  companyDevices: { id: string; mac_address: string | null }[],
  rule: AlertRule,
): Promise<NewAlert[]> {
  const weeksBack = (rule.config?.weeks_lookback as number) ?? 4
  const minExpected = (rule.config?.min_expected_sales as number) ?? 1
  const now = new Date()
  const currentDow = now.getDay() // 0=Sunday
  const currentHour = now.getHours()

  // Get machines for this company
  const { data: machines } = await client
    .from('vendingMachine')
    .select('id, name, embedded')
    .eq('company', companyId)
    .not('embedded', 'is', null)

  if (!machines || machines.length === 0) return []

  const machineIds = machines.map(m => m.id)
  const lookbackDate = new Date(now.getTime() - weeksBack * 7 * 24 * 60 * 60 * 1000).toISOString()

  // Get historical avg sales for this weekday+hour
  const { data: patterns } = await client.rpc('get_sales_pattern', {
    p_machine_ids: machineIds,
    p_dow: currentDow,
    p_hour: currentHour,
    p_since: lookbackDate,
  })

  if (!patterns || patterns.length === 0) return []

  // Get current hour's sales
  const hourStart = new Date(now.getFullYear(), now.getMonth(), now.getDate(), currentHour).toISOString()
  const hourEnd = new Date(now.getFullYear(), now.getMonth(), now.getDate(), currentHour + 1).toISOString()

  const { data: currentSales } = await client
    .from('sales')
    .select('machine_id')
    .in('machine_id', machineIds)
    .gte('created_at', hourStart)
    .lt('created_at', hourEnd)

  const currentCounts = new Map<string, number>()
  for (const s of currentSales ?? []) {
    currentCounts.set(s.machine_id, (currentCounts.get(s.machine_id) ?? 0) + 1)
  }

  const histMap = new Map<string, number>(
    (patterns as { machine_id: string; avg_sales: number }[]).map(h => [h.machine_id, Number(h.avg_sales)])
  )

  const dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
  const alerts: NewAlert[] = []

  for (const machine of machines) {
    const expected = histMap.get(machine.id) ?? 0
    const actual = currentCounts.get(machine.id) ?? 0

    if (expected >= minExpected && actual === 0) {
      alerts.push({
        company_id: companyId,
        embedded_id: machine.embedded,
        machine_id: machine.id,
        alert_type: 'no_sales_anomaly',
        severity: 'warning',
        title: 'No Sales Anomaly',
        message: `${machine.name} has 0 sales this hour but typically has ${expected.toFixed(1)} (${dayNames[currentDow]} ${currentHour}:00).`,
        metadata: { expected, actual: 0, dow: currentDow, hour: currentHour },
      })
    }
  }

  return alerts
}
```

**Step 3: Add config.toml entry**

Add to end of `Docker/supabase/config.toml`:

```toml
[functions.check-alerts]
enabled = true
verify_jwt = false
import_map = "./functions/check-alerts/deno.json"
entrypoint = "./functions/check-alerts/index.ts"
```

**Step 4: Test the edge function manually**

Run: `cd Docker/supabase && supabase functions serve check-alerts`
Then: `curl -X POST http://127.0.0.1:54321/functions/v1/check-alerts -H "X-Webhook-Secret: $(grep MQTT_WEBHOOK_SECRET .env | cut -d= -f2)" -H "Content-Type: application/json" -d '{}'`
Expected: `{"ok":true,"alerts_created":0}`

**Step 5: Commit**

```bash
git add Docker/supabase/functions/check-alerts/ Docker/supabase/config.toml
git commit -m "feat: add check-alerts edge function with 5 alert types"
```

---

## Task 4: Frontend Composable — useAlerts

**Files:**
- Create: `management-frontend/app/composables/useAlerts.ts`

**Step 1: Write the composable**

```typescript
import { useSupabaseClient } from '#imports'

const PAGE_SIZE = 50

export interface Alert {
  id: string
  created_at: string
  company_id: string
  embedded_id: string | null
  machine_id: string | null
  alert_type: string
  severity: string
  title: string
  message: string
  metadata: Record<string, unknown>
  status: string
  acknowledged_at: string | null
  acknowledged_by: string | null
}

export interface AlertRule {
  id: string
  company_id: string
  alert_type: string
  enabled: boolean
  config: Record<string, unknown>
  cooldown_minutes: number
}

export function useAlerts() {
  const supabase = useSupabaseClient()

  const alerts = ref<Alert[]>([])
  const rules = ref<AlertRule[]>([])
  const openCount = ref(0)
  const loading = ref(false)
  const hasMore = ref(true)

  // Filters
  const statusFilter = ref<string>('open')
  const typeFilter = ref<string>('')
  const severityFilter = ref<string>('')

  async function fetchAlerts() {
    loading.value = true
    try {
      let query = supabase
        .from('alerts')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(PAGE_SIZE)

      if (statusFilter.value) query = query.eq('status', statusFilter.value)
      if (typeFilter.value) query = query.eq('alert_type', typeFilter.value)
      if (severityFilter.value) query = query.eq('severity', severityFilter.value)

      const { data } = await query
      alerts.value = (data ?? []) as Alert[]
      hasMore.value = (data ?? []).length >= PAGE_SIZE
    } finally {
      loading.value = false
    }
  }

  async function fetchMore() {
    if (!hasMore.value || alerts.value.length === 0) return
    loading.value = true
    try {
      const oldest = alerts.value[alerts.value.length - 1].created_at
      let query = supabase
        .from('alerts')
        .select('*')
        .lt('created_at', oldest)
        .order('created_at', { ascending: false })
        .limit(PAGE_SIZE)

      if (statusFilter.value) query = query.eq('status', statusFilter.value)
      if (typeFilter.value) query = query.eq('alert_type', typeFilter.value)
      if (severityFilter.value) query = query.eq('severity', severityFilter.value)

      const { data } = await query
      const page = (data ?? []) as Alert[]
      alerts.value.push(...page)
      hasMore.value = page.length >= PAGE_SIZE
    } finally {
      loading.value = false
    }
  }

  async function fetchOpenCount() {
    const { count } = await supabase
      .from('alerts')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'open')
    openCount.value = count ?? 0
  }

  async function acknowledgeAlert(alertId: string) {
    const { error } = await supabase
      .from('alerts')
      .update({
        status: 'acknowledged',
        acknowledged_at: new Date().toISOString(),
      })
      .eq('id', alertId)

    if (!error) {
      const idx = alerts.value.findIndex(a => a.id === alertId)
      if (idx >= 0) {
        alerts.value[idx].status = 'acknowledged'
        alerts.value[idx].acknowledged_at = new Date().toISOString()
      }
      openCount.value = Math.max(0, openCount.value - 1)
    }
  }

  async function acknowledgeAll() {
    const { error } = await supabase
      .from('alerts')
      .update({
        status: 'acknowledged',
        acknowledged_at: new Date().toISOString(),
      })
      .eq('status', 'open')

    if (!error) {
      for (const a of alerts.value) {
        if (a.status === 'open') {
          a.status = 'acknowledged'
          a.acknowledged_at = new Date().toISOString()
        }
      }
      openCount.value = 0
    }
  }

  async function fetchRules() {
    const { data } = await supabase
      .from('alert_rules')
      .select('*')
      .order('alert_type')
    rules.value = (data ?? []) as AlertRule[]
  }

  async function updateRule(ruleId: string, updates: Partial<Pick<AlertRule, 'enabled' | 'config' | 'cooldown_minutes'>>) {
    const { error } = await supabase
      .from('alert_rules')
      .update({ ...updates, updated_at: new Date().toISOString() })
      .eq('id', ruleId)

    if (!error) {
      const idx = rules.value.findIndex(r => r.id === ruleId)
      if (idx >= 0) Object.assign(rules.value[idx], updates)
    }
  }

  function subscribe() {
    const channel = supabase
      .channel('alerts-realtime')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'alerts' }, (payload) => {
        const newAlert = payload.new as Alert
        alerts.value.unshift(newAlert)
        if (newAlert.status === 'open') openCount.value++
      })
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'alerts' }, (payload) => {
        const updated = payload.new as Alert
        const idx = alerts.value.findIndex(a => a.id === updated.id)
        if (idx >= 0) alerts.value[idx] = updated
        fetchOpenCount()
      })
      .subscribe()

    return () => { supabase.removeChannel(channel) }
  }

  // Helper: human-readable alert type label
  function alertTypeLabel(type: string): string {
    const labels: Record<string, string> = {
      device_offline: 'Device Offline',
      no_sales_anomaly: 'No Sales',
      mdb_error: 'MDB Error',
      ota_failure: 'OTA Failure',
      high_checksum_errors: 'Checksum Errors',
    }
    return labels[type] ?? type
  }

  // Helper: badge variant for severity
  function severityVariant(severity: string): 'default' | 'secondary' | 'destructive' | 'outline' {
    switch (severity) {
      case 'critical': return 'destructive'
      case 'warning': return 'default'
      case 'info': return 'secondary'
      default: return 'outline'
    }
  }

  return {
    alerts, rules, openCount, loading, hasMore,
    statusFilter, typeFilter, severityFilter,
    fetchAlerts, fetchMore, fetchOpenCount,
    acknowledgeAlert, acknowledgeAll,
    fetchRules, updateRule,
    subscribe,
    alertTypeLabel, severityVariant,
  }
}
```

**Step 2: Commit**

```bash
git add management-frontend/app/composables/useAlerts.ts
git commit -m "feat: add useAlerts composable for alert management"
```

---

## Task 5: Notification Type Registration

**Files:**
- Modify: `management-frontend/app/composables/useNotifications.ts` (~line 10-21)

**Step 1: Add alert notification types to the array**

Add after the existing `low_stock` entry in the `notificationTypes` array:

```typescript
  {
    key: 'alert_device_offline',
    label: 'Device offline alerts',
    description: 'Get notified when a device stops sending heartbeats.',
  },
  {
    key: 'alert_no_sales_anomaly',
    label: 'No sales anomaly alerts',
    description: 'Get notified when a machine has unexpectedly low sales.',
  },
  {
    key: 'alert_mdb_error',
    label: 'MDB error alerts',
    description: 'Get notified about MDB communication errors.',
  },
  {
    key: 'alert_ota_failure',
    label: 'OTA failure alerts',
    description: 'Get notified when a firmware update fails.',
  },
  {
    key: 'alert_high_checksum_errors',
    label: 'Checksum error alerts',
    description: 'Get notified about high MDB checksum error rates.',
  },
```

**Step 2: Commit**

```bash
git add management-frontend/app/composables/useNotifications.ts
git commit -m "feat: add alert notification types to notification preferences"
```

---

## Task 6: i18n Locale Keys

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

**Step 1: Add nav key and alerts section to en.json**

Add `"alerts": "Alerts"` to the `"nav"` object.

Add a new `"alerts"` section:

```json
  "alerts": {
    "title": "Alerts",
    "subtitle": "Operational alerts — updated in real time",
    "allStatuses": "All statuses",
    "open": "Open",
    "acknowledged": "Acknowledged",
    "resolved": "Resolved",
    "allTypes": "All types",
    "allSeverities": "All severities",
    "info": "Info",
    "warning": "Warning",
    "critical": "Critical",
    "clearFilters": "Clear filters",
    "acknowledgeAll": "Acknowledge all",
    "acknowledge": "Acknowledge",
    "timeCol": "Time",
    "typeCol": "Type",
    "severityCol": "Severity",
    "messageCol": "Message",
    "statusCol": "Status",
    "actionsCol": "",
    "noAlerts": "No alerts",
    "alertsWillAppear": "Alerts will appear here when operational issues are detected.",
    "loadMore": "Load more",
    "configuration": "Alert Configuration",
    "configSubtitle": "Configure thresholds and cooldown periods for each alert type.",
    "enabled": "Enabled",
    "cooldown": "Cooldown (minutes)",
    "offlineMinutes": "Offline threshold (minutes)",
    "minExpectedSales": "Min expected sales",
    "weeksLookback": "Weeks lookback",
    "errorThreshold": "Error threshold",
    "deviceOffline": "Device Offline",
    "noSalesAnomaly": "No Sales Anomaly",
    "mdbError": "MDB Error",
    "otaFailure": "OTA Failure",
    "highChecksumErrors": "High Checksum Errors"
  }
```

**Step 2: Add corresponding German translations to de.json**

Add `"alerts": "Alarme"` to the `"nav"` object.

Add a new `"alerts"` section:

```json
  "alerts": {
    "title": "Alarme",
    "subtitle": "Betriebsalarme — werden in Echtzeit aktualisiert",
    "allStatuses": "Alle Status",
    "open": "Offen",
    "acknowledged": "Bestätigt",
    "resolved": "Behoben",
    "allTypes": "Alle Typen",
    "allSeverities": "Alle Schweregrade",
    "info": "Info",
    "warning": "Warnung",
    "critical": "Kritisch",
    "clearFilters": "Filter zurücksetzen",
    "acknowledgeAll": "Alle bestätigen",
    "acknowledge": "Bestätigen",
    "timeCol": "Zeit",
    "typeCol": "Typ",
    "severityCol": "Schweregrad",
    "messageCol": "Nachricht",
    "statusCol": "Status",
    "actionsCol": "",
    "noAlerts": "Keine Alarme",
    "alertsWillAppear": "Alarme erscheinen hier, wenn Betriebsprobleme erkannt werden.",
    "loadMore": "Mehr laden",
    "configuration": "Alarm-Konfiguration",
    "configSubtitle": "Schwellenwerte und Abklingzeiten für jeden Alarmtyp konfigurieren.",
    "enabled": "Aktiviert",
    "cooldown": "Abklingzeit (Minuten)",
    "offlineMinutes": "Offline-Schwellenwert (Minuten)",
    "minExpectedSales": "Min. erwartete Verkäufe",
    "weeksLookback": "Wochen Rückblick",
    "errorThreshold": "Fehlerschwellenwert",
    "deviceOffline": "Gerät Offline",
    "noSalesAnomaly": "Fehlende Verkäufe",
    "mdbError": "MDB-Fehler",
    "otaFailure": "OTA-Fehler",
    "highChecksumErrors": "Hohe Prüfsummenfehler"
  }
```

**Step 3: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat: add i18n keys for alerts page (en + de)"
```

---

## Task 7: Alerts Page

**Files:**
- Create: `management-frontend/app/pages/alerts/index.vue`

**Step 1: Write the alerts page**

Follow the exact pattern from `pages/history/index.vue`. The page has three sections: alert list with filters, and an admin-only configuration panel.

```vue
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { timeAgo } from '@/lib/utils'
import { useAlerts } from '@/composables/useAlerts'
import { Badge } from '@/components/ui/badge'

const { t } = useI18n()
const { role } = useOrganization()

const {
  alerts,
  rules,
  openCount,
  loading,
  hasMore,
  statusFilter,
  typeFilter,
  severityFilter,
  fetchAlerts,
  fetchMore,
  fetchOpenCount,
  acknowledgeAlert,
  acknowledgeAll,
  fetchRules,
  updateRule,
  subscribe,
  alertTypeLabel,
  severityVariant,
} = useAlerts()

const ALERT_TYPES = computed(() => [
  { value: '', label: t('alerts.allTypes') },
  { value: 'device_offline', label: t('alerts.deviceOffline') },
  { value: 'no_sales_anomaly', label: t('alerts.noSalesAnomaly') },
  { value: 'mdb_error', label: t('alerts.mdbError') },
  { value: 'ota_failure', label: t('alerts.otaFailure') },
  { value: 'high_checksum_errors', label: t('alerts.highChecksumErrors') },
])

const STATUSES = computed(() => [
  { value: '', label: t('alerts.allStatuses') },
  { value: 'open', label: t('alerts.open') },
  { value: 'acknowledged', label: t('alerts.acknowledged') },
  { value: 'resolved', label: t('alerts.resolved') },
])

const SEVERITIES = computed(() => [
  { value: '', label: t('alerts.allSeverities') },
  { value: 'critical', label: t('alerts.critical') },
  { value: 'warning', label: t('alerts.warning') },
  { value: 'info', label: t('alerts.info') },
])

const showConfig = ref(false)

watch([statusFilter, typeFilter, severityFilter], () => fetchAlerts())

let unsubscribe: (() => void) | null = null

onMounted(async () => {
  await Promise.all([fetchAlerts(), fetchOpenCount()])
  if (role.value === 'admin') await fetchRules()
  unsubscribe = subscribe()
})

onUnmounted(() => {
  unsubscribe?.()
})

function ruleLabel(type: string): string {
  const labels: Record<string, string> = {
    device_offline: t('alerts.deviceOffline'),
    no_sales_anomaly: t('alerts.noSalesAnomaly'),
    mdb_error: t('alerts.mdbError'),
    ota_failure: t('alerts.otaFailure'),
    high_checksum_errors: t('alerts.highChecksumErrors'),
  }
  return labels[type] ?? type
}

function configFields(rule: { alert_type: string; config: Record<string, unknown> }) {
  switch (rule.alert_type) {
    case 'device_offline':
      return [{ key: 'offline_minutes', label: t('alerts.offlineMinutes'), value: rule.config.offline_minutes ?? 30 }]
    case 'no_sales_anomaly':
      return [
        { key: 'min_expected_sales', label: t('alerts.minExpectedSales'), value: rule.config.min_expected_sales ?? 1 },
        { key: 'weeks_lookback', label: t('alerts.weeksLookback'), value: rule.config.weeks_lookback ?? 4 },
      ]
    case 'high_checksum_errors':
      return [{ key: 'error_threshold', label: t('alerts.errorThreshold'), value: rule.config.error_threshold ?? 50 }]
    default:
      return []
  }
}

async function toggleRule(rule: { id: string; enabled: boolean }) {
  await updateRule(rule.id, { enabled: !rule.enabled })
}

async function updateConfig(ruleId: string, config: Record<string, unknown>, key: string, value: string) {
  const numVal = Number(value)
  if (isNaN(numVal) || numVal < 0) return
  await updateRule(ruleId, { config: { ...config, [key]: numVal } })
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <!-- Header -->
    <div class="flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">{{ t('alerts.title') }}</h1>
        <p class="text-sm text-muted-foreground">{{ t('alerts.subtitle') }}</p>
      </div>
      <div class="flex gap-2">
        <button
          v-if="role === 'admin'"
          class="h-9 rounded-md border border-input px-3 text-sm hover:bg-muted"
          @click="showConfig = !showConfig"
        >
          {{ t('alerts.configuration') }}
        </button>
        <button
          v-if="openCount > 0 && role === 'admin'"
          class="h-9 rounded-md bg-primary px-3 text-sm text-primary-foreground hover:bg-primary/90"
          @click="acknowledgeAll()"
        >
          {{ t('alerts.acknowledgeAll') }} ({{ openCount }})
        </button>
      </div>
    </div>

    <!-- Configuration panel (admin only) -->
    <div v-if="showConfig && role === 'admin'" class="rounded-lg border p-4 space-y-4">
      <div>
        <h2 class="text-lg font-semibold">{{ t('alerts.configuration') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('alerts.configSubtitle') }}</p>
      </div>
      <div class="space-y-3">
        <div
          v-for="rule in rules"
          :key="rule.id"
          class="flex flex-wrap items-center gap-4 rounded-md border p-3"
        >
          <label class="flex items-center gap-2 min-w-[200px]">
            <input
              type="checkbox"
              :checked="rule.enabled"
              class="h-4 w-4 rounded border-input"
              @change="toggleRule(rule)"
            />
            <span class="text-sm font-medium">{{ ruleLabel(rule.alert_type) }}</span>
          </label>
          <div class="flex flex-wrap items-center gap-3">
            <label v-for="field in configFields(rule)" :key="field.key" class="flex items-center gap-1.5">
              <span class="text-xs text-muted-foreground">{{ field.label }}</span>
              <input
                type="number"
                :value="field.value"
                min="0"
                class="h-8 w-20 rounded-md border border-input bg-background px-2 text-sm"
                @change="updateConfig(rule.id, rule.config, field.key, ($event.target as HTMLInputElement).value)"
              />
            </label>
            <label class="flex items-center gap-1.5">
              <span class="text-xs text-muted-foreground">{{ t('alerts.cooldown') }}</span>
              <input
                type="number"
                :value="rule.cooldown_minutes"
                min="0"
                class="h-8 w-20 rounded-md border border-input bg-background px-2 text-sm"
                @change="updateRule(rule.id, { cooldown_minutes: Number(($event.target as HTMLInputElement).value) })"
              />
            </label>
          </div>
        </div>
      </div>
    </div>

    <!-- Filters -->
    <div class="flex flex-wrap gap-3">
      <select
        v-model="statusFilter"
        class="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
      >
        <option v-for="opt in STATUSES" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
      </select>
      <select
        v-model="typeFilter"
        class="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
      >
        <option v-for="opt in ALERT_TYPES" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
      </select>
      <select
        v-model="severityFilter"
        class="h-9 rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus:outline-none focus:ring-1 focus:ring-ring"
      >
        <option v-for="opt in SEVERITIES" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
      </select>
      <button
        v-if="statusFilter || typeFilter || severityFilter"
        class="h-9 rounded-md border border-input px-3 py-1 text-sm text-muted-foreground hover:bg-muted"
        @click="statusFilter = ''; typeFilter = ''; severityFilter = ''"
      >
        {{ t('alerts.clearFilters') }}
      </button>
    </div>

    <!-- Loading skeleton -->
    <div v-if="loading && alerts.length === 0" class="space-y-2">
      <div v-for="i in 8" :key="i" class="h-14 animate-pulse rounded-lg bg-muted" />
    </div>

    <!-- Empty state -->
    <div
      v-else-if="!loading && alerts.length === 0"
      class="flex flex-col items-center justify-center gap-2 py-24 text-center text-muted-foreground"
    >
      <p class="font-medium">{{ t('alerts.noAlerts') }}</p>
      <p class="text-sm">{{ t('alerts.alertsWillAppear') }}</p>
    </div>

    <!-- Alert table -->
    <div v-else class="overflow-x-auto rounded-lg border">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b bg-muted/50">
            <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('alerts.timeCol') }}</th>
            <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('alerts.severityCol') }}</th>
            <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('alerts.typeCol') }}</th>
            <th class="px-4 py-3 text-left font-medium text-muted-foreground">{{ t('alerts.messageCol') }}</th>
            <th class="hidden sm:table-cell px-4 py-3 text-left font-medium text-muted-foreground">{{ t('alerts.statusCol') }}</th>
            <th class="px-4 py-3 text-right font-medium text-muted-foreground">{{ t('alerts.actionsCol') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="alert in alerts"
            :key="alert.id"
            class="border-b transition-colors last:border-0 hover:bg-muted/30"
          >
            <td class="whitespace-nowrap px-4 py-3 text-muted-foreground">
              <span :title="new Date(alert.created_at).toLocaleString()">
                {{ timeAgo(alert.created_at, t) }}
              </span>
            </td>
            <td class="px-4 py-3">
              <Badge :variant="severityVariant(alert.severity)" class="capitalize">
                {{ alert.severity }}
              </Badge>
            </td>
            <td class="px-4 py-3">
              <span class="text-sm font-medium">{{ alertTypeLabel(alert.alert_type) }}</span>
            </td>
            <td class="px-4 py-3 max-w-md">
              <p class="text-sm">{{ alert.message }}</p>
            </td>
            <td class="hidden sm:table-cell px-4 py-3">
              <Badge :variant="alert.status === 'open' ? 'default' : 'outline'" class="capitalize">
                {{ alert.status }}
              </Badge>
            </td>
            <td class="px-4 py-3 text-right">
              <button
                v-if="alert.status === 'open' && role === 'admin'"
                class="rounded-md border border-input px-2 py-1 text-xs hover:bg-muted"
                @click="acknowledgeAlert(alert.id)"
              >
                {{ t('alerts.acknowledge') }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Load more -->
    <div v-if="hasMore && alerts.length > 0" class="flex justify-center">
      <button
        :disabled="loading"
        class="rounded-md border border-input px-4 py-2 text-sm hover:bg-muted disabled:opacity-50"
        @click="fetchMore"
      >
        {{ loading ? t('common.loading') : t('alerts.loadMore') }}
      </button>
    </div>
  </div>
</template>
```

**Step 2: Commit**

```bash
git add management-frontend/app/pages/alerts/index.vue
git commit -m "feat: add /alerts page with filters, table, and config panel"
```

---

## Task 8: Navigation — Sidebar + Alert Badge

**Files:**
- Create: `management-frontend/app/components/AlertBadge.vue`
- Modify: `management-frontend/app/components/AppSidebar.vue`

**Step 1: Create AlertBadge component**

```vue
<script setup lang="ts">
import { useAlerts } from '@/composables/useAlerts'

const { openCount, fetchOpenCount, subscribe } = useAlerts()

let unsubscribe: (() => void) | null = null

onMounted(async () => {
  await fetchOpenCount()
  unsubscribe = subscribe()
})

onUnmounted(() => {
  unsubscribe?.()
})
</script>

<template>
  <span
    v-if="openCount > 0"
    class="ml-auto inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-destructive px-1.5 text-[10px] font-medium text-destructive-foreground"
  >
    {{ openCount > 99 ? '99+' : openCount }}
  </span>
</template>
```

**Step 2: Update AppSidebar.vue**

Add `IconBell` to the imports:

```typescript
import {
  IconBell,
  IconBuildingWarehouse,
  // ... existing imports
} from "@tabler/icons-vue"
```

Add the Alerts nav item in the `navMain` computed, right after the "history" entry (before the admin-only section):

```typescript
    {
      title: t('nav.alerts'),
      url: "/alerts",
      icon: IconBell,
    },
```

**Step 3: Commit**

```bash
git add management-frontend/app/components/AlertBadge.vue management-frontend/app/components/AppSidebar.vue
git commit -m "feat: add alerts navigation with badge in sidebar"
```

---

## Task 9: Verification

**Step 1: Reset database and verify migration**

Run: `cd Docker/supabase && supabase db reset`
Expected: All migrations pass. Check `alerts` and `alert_rules` tables exist with default rules.

**Step 2: Test edge function**

Run: `curl -X POST http://127.0.0.1:54321/functions/v1/check-alerts -H "X-Webhook-Secret: $(grep MQTT_WEBHOOK_SECRET .env | cut -d= -f2)" -H "Content-Type: application/json" -d '{}'`
Expected: `{"ok":true,"alerts_created":0}`

**Step 3: Verify frontend compiles**

Run: `cd management-frontend && npm run dev`
Expected: No compilation errors. Navigate to `/alerts` — shows empty state. Sidebar shows "Alerts" nav item.

**Step 4: Manual integration test**

Insert a test alert via Supabase Studio or SQL:
```sql
INSERT INTO alerts (company_id, alert_type, severity, title, message)
SELECT id, 'device_offline', 'critical', 'Test Alert', 'This is a test alert'
FROM companies LIMIT 1;
```
Expected: Alert appears on `/alerts` page in real-time. Badge shows "1".

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat: complete alerting system with pg_cron, edge function, and frontend"
```
