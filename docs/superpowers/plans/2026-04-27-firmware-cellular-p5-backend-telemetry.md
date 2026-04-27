# Firmware Cellular P5 — Backend Telemetry Surface

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a cellular device's signal/operator/mode/IP visible end-to-end: firmware appends them to the existing `online|v:…|b:…` status MQTT payload (additive, backward-compatible); the `mqtt-webhook` Edge Function parses any extra `key:value` segments and merges them into `embeddeds.mdb_diagnostics` jsonb; the Vue frontend renders a small `CellularHealthBadge` on the devices list and machine-detail pages.

**Architecture:** Pipe-delimited extension chosen over JSON-replacement to preserve byte-for-byte compatibility with the existing field firmware (`online|v:VER|b:BUILD`). Old firmware emits 3 segments; new cellular firmware emits 7 (adds `uplink:cellular`, `op:NAME`, `rssi:-78`, `mode:LTE-M`, `ip:10.0.0.1`). The mqtt-webhook function already splits on `|` and reads `parts[0..2]`; we extend it to walk `parts[3..]` for `key:value` pairs and write them into the existing jsonb column. Frontend is a 100-line Vue component + i18n strings + a Vitest snapshot.

**Tech Stack:** ESP-IDF (firmware), Deno (mqtt-webhook), Vue 3 + Nuxt 4 + Vitest + Tailwind (frontend), no DB migration (jsonb is additive by definition).

**Spec reference:** [docs/superpowers/specs/2026-04-27-firmware-cellular-network-design.md](../specs/2026-04-27-firmware-cellular-network-design.md) — see §6 (Backend & frontend impact).

**Position in milestone:** Phase 5 of 6. P1+P2+P3+P4 complete. P6 (field validation) is the only phase left after this.

**Backward-compat invariants:**
- Old firmware (3-segment status) MUST still be parsed correctly. The new mqtt-webhook code MUST treat segments beyond `parts[2]` as optional.
- Frontend: when `mdb_diagnostics` lacks the new cellular fields, the badge renders nothing (no error, no empty placeholder).
- No DB migration. No edge function added. No new MQTT topic.

---

## File Structure

- **Modify:** `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` — extend the `snprintf` that builds `status_msg` (currently `online|v:%s|b:%s %s %s`) to also include cellular fields when uplink is cellular. Pulls from `network_get_status()`.
- **Modify:** `Docker/supabase/functions/mqtt-webhook/index.ts` — in the existing `if (eventType === 'status')` block, after the existing `firmware_version` / `build_date` parse, walk `parts.slice(3)` for `key:value` pairs and merge into a `cellular: {...}` block in `embeddeds.mdb_diagnostics`.
- **Create:** `management-frontend/app/components/CellularHealthBadge.vue` — props `{ diagnostics: object | null }`. Renders nothing when `diagnostics?.cellular?.uplink !== 'cellular'`. Otherwise: signal bars (4-step from dBm) + operator name + mode pill. Tooltip shows exact dBm + IP.
- **Create:** `management-frontend/app/components/__tests__/CellularHealthBadge.test.ts` — Vitest snapshot covering: no diagnostics → renders nothing; with cellular → signal bars + operator + mode; boundary dBm values (-50/-80/-100 → 4/2/0 bars).
- **Modify:** `management-frontend/app/pages/devices.vue` — mount `<CellularHealthBadge :diagnostics="device.mdb_diagnostics" />` per row.
- **Modify:** `management-frontend/app/pages/machines/[id].vue` — mount in the existing status indicator area.
- **Modify:** `management-frontend/i18n/locales/en.json` and `management-frontend/i18n/locales/de.json` — two new keys under `cellularHealth`: `signal`, `mode`.
- **Modify:** `CLAUDE.md` — add a paragraph noting the new cellular fields in `mdb_diagnostics` and the Vue badge.

---

## Chunk 1: Firmware + Backend (Tasks 1–2)

### Task 1: Extend firmware status payload with cellular fields

**Files:** Modify `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`.

The current code (around line 1893) reads:
```c
char status_msg[128];
snprintf(status_msg, sizeof(status_msg), "online|v:%s|b:%s %s %s",
         app_desc->version, app_desc->date, app_desc->time, BUILD_TIMEZONE);
```

- [ ] **Step 1:** Replace with a build that conditionally appends cellular fields when `network_get_status().modem_present` is true:

```c
char status_msg[256];   /* bumped from 128 to fit cellular fields */
int n = snprintf(status_msg, sizeof(status_msg), "online|v:%s|b:%s %s %s",
                  app_desc->version, app_desc->date, app_desc->time, BUILD_TIMEZONE);

network_status_t ns;
network_get_status(&ns);
if (ns.modem_present && n > 0 && n < (int)sizeof(status_msg)) {
    /* lte_mode_t enum to short string, mirroring the captive-portal helper */
    const char *mode_str = (ns.cellular_mode == MODEM_LTE_MODE_CATM)  ? "LTE-M"  :
                            (ns.cellular_mode == MODEM_LTE_MODE_NBIOT) ? "NB-IoT" :
                            (ns.cellular_mode == MODEM_LTE_MODE_BOTH)  ? "Auto"   : "?";
    snprintf(status_msg + n, sizeof(status_msg) - n,
             "|uplink:cellular|op:%s|rssi:%d|mode:%s|ip:%s",
             ns.cellular_operator[0] ? ns.cellular_operator : "unknown",
             ns.cellular_rssi_dbm,
             mode_str,
             ns.cellular_ip[0] ? ns.cellular_ip : "0.0.0.0");
}
```

Add `#include "network.h"` near the top of the file if not already present.

- [ ] **Step 2:** Build clean. Commit `firmware(status): append cellular fields (op/rssi/mode/ip) to status payload`.

### Task 2: Extend mqtt-webhook to parse extra status segments

**Files:** Modify `Docker/supabase/functions/mqtt-webhook/index.ts`.

The current handler (around line 90) parses:
```ts
const parts = rawStatus.split('|');
const status = parts[0];
// parts[1] = "v:1.0.0"
// parts[2] = "b:..."
```

- [ ] **Step 1:** Find the existing status block. After the existing `firmware_version` / `build_date` extraction but before the database update, add:

```ts
// Parse extra key:value segments (parts[3+]) into a cellular block.
// Old firmware sends only 3 parts; new cellular firmware sends extras
// like "uplink:cellular|op:Vodafone DE|rssi:-78|mode:LTE-M|ip:10.0.0.1".
const cellular: Record<string, string | number> = {};
for (const seg of parts.slice(3)) {
  const colonIdx = seg.indexOf(':');
  if (colonIdx <= 0) continue;
  const key = seg.slice(0, colonIdx).trim();
  const val = seg.slice(colonIdx + 1).trim();
  if (!key || !val) continue;
  if (key === 'rssi') {
    const n = parseInt(val, 10);
    if (!Number.isNaN(n)) cellular[key] = n;
  } else {
    cellular[key] = val;
  }
}
```

- [ ] **Step 2:** Where `embeddeds` is updated for status, also merge `cellular` into the `mdb_diagnostics` jsonb. The existing handler already updates `status`, `status_at`, `firmware_version`, `build_date` on the `embeddeds` row. Add:

```ts
// Merge cellular telemetry into mdb_diagnostics jsonb if present.
let mdbDiagnosticsPatch: Record<string, unknown> | null = null;
if (Object.keys(cellular).length > 0) {
  // Read-modify-write so we don't clobber other diagnostic fields the
  // mdb-log handler may have written.
  const { data: existing } = await adminClient
    .from('embeddeds')
    .select('mdb_diagnostics')
    .eq('id', embeddedRow.id)
    .single();
  const prev = (existing?.mdb_diagnostics as Record<string, unknown> | null) ?? {};
  mdbDiagnosticsPatch = { ...prev, cellular };
}

const updatePayload: Record<string, unknown> = {
  status,
  status_at: new Date().toISOString(),
  firmware_version,
  build_date,
};
if (mdbDiagnosticsPatch) updatePayload.mdb_diagnostics = mdbDiagnosticsPatch;

await adminClient
  .from('embeddeds')
  .update(updatePayload)
  .eq('id', embeddedRow.id);
```

(Adjust to fit the actual existing code structure — the row variable name and the .update() call shape may differ.)

- [ ] **Step 3:** No automated test (the existing function has only a Deno test for mdb-log; pattern is fine). Commit `edge(mqtt-webhook): parse cellular telemetry from status payload into mdb_diagnostics`.

---

## Chunk 2: Frontend (Tasks 3–6)

### Task 3: CellularHealthBadge.vue component

**Files:** Create `management-frontend/app/components/CellularHealthBadge.vue`.

- [ ] **Step 1:** Create the component:

```vue
<script setup lang="ts">
const props = defineProps<{
  diagnostics?: Record<string, any> | null;
}>();

const cellular = computed(() => {
  const c = props.diagnostics?.cellular;
  if (!c || c.uplink !== 'cellular') return null;
  return c;
});

/* dBm → 0..4 bars: ≥-65=4, ≥-80=3, ≥-95=2, ≥-105=1, else 0 */
const bars = computed(() => {
  const dbm = cellular.value?.rssi;
  if (typeof dbm !== 'number') return 0;
  if (dbm >= -65)  return 4;
  if (dbm >= -80)  return 3;
  if (dbm >= -95)  return 2;
  if (dbm >= -105) return 1;
  return 0;
});

const tooltip = computed(() => {
  const c = cellular.value;
  if (!c) return '';
  const parts: string[] = [];
  if (typeof c.rssi === 'number') parts.push(`${c.rssi} dBm`);
  if (c.ip)                       parts.push(`IP ${c.ip}`);
  return parts.join(' · ');
});
</script>

<template>
  <div v-if="cellular" class="inline-flex items-center gap-2 text-xs" :title="tooltip">
    <!-- signal bars -->
    <span class="inline-flex items-end gap-px h-3.5">
      <span v-for="i in 4" :key="i"
            class="w-1 rounded-sm transition-colors"
            :class="i <= bars ? 'bg-lime-400' : 'bg-slate-700'"
            :style="{ height: `${i * 25}%` }" />
    </span>
    <!-- operator -->
    <span class="text-slate-300">{{ cellular.op || '—' }}</span>
    <!-- mode pill -->
    <span class="px-1.5 py-px rounded text-[10px] font-medium bg-slate-700 text-slate-200">
      {{ cellular.mode || '—' }}
    </span>
  </div>
</template>
```

- [ ] **Step 2:** No build required for this file alone. Commit `frontend(badge): CellularHealthBadge.vue component (signal bars + operator + mode pill)`.

### Task 4: Mount in /devices and /machines/[id]

**Files:** Modify `management-frontend/app/pages/devices.vue` and `management-frontend/app/pages/machines/[id].vue`.

- [ ] **Step 1:** In `devices.vue`, locate the table row rendering that shows device status. Add `<CellularHealthBadge :diagnostics="row.mdb_diagnostics" />` next to the existing status indicator. Component is auto-imported by Nuxt — no script change needed.
- [ ] **Step 2:** In `machines/[id].vue`, find the status indicator near the top of the per-machine view (probably in the header or the machine-info card). Add the badge there.
- [ ] **Step 3:** Run `cd management-frontend && npm run typecheck` (or `npx vue-tsc --noEmit`) if typecheck is part of the project's normal dev loop. Commit `frontend(badge): mount CellularHealthBadge in /devices and /machines/[id]`.

### Task 5: i18n strings

**Files:** Modify `management-frontend/i18n/locales/en.json` and `de.json`.

The component as written above uses no i18n strings (operator/mode come from device data; "—" is a unicode placeholder). If a tooltip helper is needed later, the keys would live under `cellularHealth.signal` / `cellularHealth.mode`. For P5 we ship without i18n keys to keep the diff minimal — the component is self-contained.

- [ ] **Step 1:** Skip — no i18n changes needed for this iteration. (Documented in the plan so a reviewer doesn't flag it as missing.)

### Task 6: Vitest snapshot test

**Files:** Create `management-frontend/app/components/__tests__/CellularHealthBadge.test.ts`.

- [ ] **Step 1:** Write the test:

```ts
import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import CellularHealthBadge from '../CellularHealthBadge.vue';

describe('CellularHealthBadge', () => {
  it('renders nothing when diagnostics is null', () => {
    const w = mount(CellularHealthBadge, { props: { diagnostics: null } });
    expect(w.html()).toBe('<!--v-if-->');
  });

  it('renders nothing when uplink is not cellular', () => {
    const w = mount(CellularHealthBadge, {
      props: { diagnostics: { cellular: { uplink: 'wifi' } } },
    });
    expect(w.html()).toBe('<!--v-if-->');
  });

  it('renders bars + operator + mode for cellular uplink', () => {
    const w = mount(CellularHealthBadge, {
      props: {
        diagnostics: {
          cellular: { uplink: 'cellular', op: 'Vodafone DE', mode: 'LTE-M', rssi: -78, ip: '10.0.0.1' },
        },
      },
    });
    expect(w.text()).toContain('Vodafone DE');
    expect(w.text()).toContain('LTE-M');
    expect(w.html()).toMatchSnapshot();
  });

  it.each([
    [-50,  4],
    [-65,  4],
    [-66,  3],
    [-80,  3],
    [-81,  2],
    [-95,  2],
    [-96,  1],
    [-105, 1],
    [-106, 0],
  ])('dBm %d → %d bars', (dbm, expected) => {
    const w = mount(CellularHealthBadge, {
      props: { diagnostics: { cellular: { uplink: 'cellular', rssi: dbm } } },
    });
    const lit = w.findAll('span.bg-lime-400').length;
    expect(lit).toBe(expected);
  });
});
```

- [ ] **Step 2:** Run tests:
```bash
cd management-frontend && npx vitest run app/components/__tests__/CellularHealthBadge.test.ts
```
Expected: all green.

- [ ] **Step 3:** Commit `frontend(badge): vitest covering null / non-cellular / dBm-to-bars boundaries`.

---

## Chunk 3: Docs (Task 7)

### Task 7: Update CLAUDE.md

**Files:** Modify `CLAUDE.md`.

- [ ] **Step 1:** Append after the "Cellular recovery (P4)" paragraph:

> **Cellular telemetry surface (P5)**: Status MQTT payload is extended additively when uplink is cellular: `online|v:VER|b:BUILD|uplink:cellular|op:NAME|rssi:DBM|mode:RAT|ip:ADDR`. The `mqtt-webhook` Edge Function parses any `key:value` segments after `parts[2]` and merges them into `embeddeds.mdb_diagnostics.cellular` jsonb (no DB migration). The frontend `CellularHealthBadge.vue` component renders signal bars + operator + mode pill on `/devices` and `/machines/[id]` when `diagnostics.cellular.uplink === 'cellular'`. Old firmware (3-segment status) is unchanged on both sides; the badge renders nothing for non-cellular devices.

- [ ] **Step 2:** Commit `firmware(network): document P5 cellular telemetry surface in CLAUDE.md`.

---

## P5 DoD

- [ ] Firmware status payload includes cellular fields when uplink is cellular (verified by serial log + by inspecting `embeddeds.mdb_diagnostics` after a real publish).
- [ ] mqtt-webhook updates the jsonb column without errors and old firmware (3-segment) still parses correctly.
- [ ] `CellularHealthBadge.vue` renders correctly for cellular devices and renders nothing for WiFi devices.
- [ ] Vitest passes (4+ test cases including dBm boundary).
- [ ] Devices list and machine detail page show the badge.
- [ ] No DB migration required.
- [ ] Build clean (firmware) + typecheck clean (frontend).
