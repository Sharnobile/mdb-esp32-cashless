# MDB Level 2/3 Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Adapt ESP32 cashless slave to respond with Level 2/3 Begin Session format based on VMC's reported feature level, and surface the VMC level in the management frontend.

**Architecture:** Store VMC feature level from SETUP CONFIG_DATA, adapt Begin Session response (3 vs 10 bytes), publish vmcLevel in mdb-log diagnostics. Backend stores it in existing mdb_diagnostics JSONB + new nullable column. Frontend displays it.

**Tech Stack:** ESP-IDF C (firmware), Deno/TypeScript (edge functions), Nuxt 4/Vue (frontend), PostgreSQL (migrations)

---

### Task 1: Firmware — Store VMC Feature Level

**Files:**
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c:148-166` (globals)
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c:314-346` (SETUP handler)

**Step 1: Add global variable for VMC feature level**

In the globals section after line 165, add:

```c
static uint8_t vmc_feature_level = 1; // VMC feature level from SETUP (default Level 1)
```

**Step 2: Store vmcFeatureLevel in SETUP CONFIG_DATA handler**

Replace lines 326 (the `(void) vmcFeatureLevel;` cast) with:

```c
vmc_feature_level = vmcFeatureLevel > 0 ? vmcFeatureLevel : 1;
```

Keep the other `(void)` casts for display info — those remain unused.

**Step 3: Adapt Reader Config Data response to report matching level**

Replace line 334 (`mdb_payload[1] = 1;`) with:

```c
mdb_payload[1] = vmc_feature_level <= 3 ? vmc_feature_level : 3; // Report up to Level 3
```

**Step 4: Commit**

```bash
git add mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
git commit -m "feat(firmware): store VMC feature level from SETUP CONFIG_DATA"
```

---

### Task 2: Firmware — Adapt Begin Session for Level 2/3

**Files:**
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c:394-405` (Begin Session in POLL handler)

**Step 1: Replace the Begin Session block (lines 394-405)**

Replace the existing Begin Session code with level-aware version:

```c
} else if (machine_state <= ENABLED_STATE && xQueueReceive(mdbSessionQueue, &fundsAvailable, 0)) {
    // Begin session
    session_begin_todo = false;

    machine_state = IDLE_STATE;

    mdb_payload[0] = 0x03;
    mdb_payload[1] = fundsAvailable >> 8;
    mdb_payload[2] = fundsAvailable;

    if (vmc_feature_level >= 2) {
        // Level 2/3: add Media ID (4) + Payment Type (1) + Payment Data (2)
        mdb_payload[3] = 0xFF; // Media ID byte 0 (no specific card)
        mdb_payload[4] = 0xFF; // Media ID byte 1
        mdb_payload[5] = 0xFF; // Media ID byte 2
        mdb_payload[6] = 0xFF; // Media ID byte 3
        mdb_payload[7] = 0x00; // Payment Type: normal vend
        mdb_payload[8] = fundsAvailable >> 8; // Payment Data = funds
        mdb_payload[9] = fundsAvailable;
        available_tx = 10;
    } else {
        available_tx = 3;
    }

    time( &session_begin_time);

    ESP_LOGI(TAG, "BEGIN_SESSION: funds=%u level=%d bytes=%d",
        fundsAvailable, vmc_feature_level, available_tx);
```

**Step 2: Verify mdb_payload buffer is large enough**

Check the declaration of `mdb_payload`. It's used for SETUP response (8 bytes) already, so it must be at least 8. Begin Session Level 2 needs 10 bytes. Verify the buffer is large enough — if declared as `uint8_t mdb_payload[8]`, increase to `[16]`.

Search for: `mdb_payload` declaration and verify size.

**Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
git commit -m "feat(firmware): send Level 2/3 Begin Session with Media ID + Payment Type"
```

---

### Task 3: Firmware — Add vmcLevel to MDB Diagnostics

**Files:**
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c:1416-1432` (publish_mdb_diag)
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c:382-386` (serial log)

**Step 1: Add vmcLevel to MQTT diagnostics JSON**

Replace the `snprintf` in `publish_mdb_diag()` (lines 1423-1429):

```c
snprintf(msg, sizeof(msg),
    "{\"state\":\"%s\",\"addr\":\"0x%02X\",\"polls\":%lu,\"chkErr\":%lu,\"lastCmd\":\"%s\",\"vmcLevel\":%u}",
    machine_state_name(machine_state),
    cashless_device_address,
    mdb_poll_count,
    mdb_checksum_errors,
    mdb_last_cmd,
    vmc_feature_level);
```

**Step 2: Add vmcLevel to periodic serial log**

Update the `ESP_LOGI` at lines 383-385:

```c
ESP_LOGI(TAG, "MDB DIAG: state=%s addr=0x%02X polls=%lu chkErr=%lu lastCmd=%s vmcLevel=%u",
    machine_state_name(machine_state), cashless_device_address,
    mdb_poll_count, mdb_checksum_errors, mdb_last_cmd, vmc_feature_level);
```

**Step 3: Commit**

```bash
git add mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
git commit -m "feat(firmware): include vmcLevel in MDB diagnostics MQTT and serial logs"
```

---

### Task 4: Database Migration — Add vmc_level Column

**Files:**
- Create: `Docker/supabase/migrations/20260312000000_mdb_vmc_level.sql`

**Step 1: Create migration file**

```sql
-- Add VMC feature level to MDB log history.
-- Nullable: old firmware won't send this field.
ALTER TABLE public.mdb_log ADD COLUMN vmc_level smallint;
```

**Step 2: Commit**

```bash
git add Docker/supabase/migrations/20260312000000_mdb_vmc_level.sql
git commit -m "feat(db): add nullable vmc_level column to mdb_log table"
```

---

### Task 5: Edge Function — Store vmcLevel in mqtt-webhook

**Files:**
- Modify: `Docker/supabase/functions/mqtt-webhook/index.ts:140-156` (mdb-log insert)

**Step 1: Add vmc_level to the mdb_log INSERT**

In the mdb-log handler, update the insert at lines 142-155 to include `vmc_level`:

```typescript
const { error: insertErr } = await adminClient
  .from('mdb_log')
  .insert({
    embedded_id: deviceId,
    state: newState,
    prev_state: prevState ?? null,
    addr: (diag.addr as string) ?? null,
    polls: (diag.polls as number) ?? null,
    chk_err: (diag.chkErr as number) ?? null,
    last_cmd: (diag.lastCmd as string) ?? null,
    vmc_level: (diag.vmcLevel as number) ?? null,
    raw: diag,
  });
```

No other changes needed — `embeddeds.mdb_diagnostics` is JSONB and already stores the full `diag` object including `vmcLevel` automatically via the spread at line 128: `{ ...diag, updated_at: ... }`.

**Step 2: Commit**

```bash
git add Docker/supabase/functions/mqtt-webhook/index.ts
git commit -m "feat(webhook): store vmcLevel from mdb-log diagnostics"
```

---

### Task 6: Edge Function Test — Add vmcLevel Test Case

**Files:**
- Modify: `Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts`

**Step 1: Add test for vmcLevel field mapping**

Add after the last test (after line 298):

```typescript
Deno.test('mdb-log: vmcLevel maps to vmc_level in history row', async () => {
  const payload = { state: 'ENABLED', addr: '0x10', polls: 100, chkErr: 0, lastCmd: 'SETUP:CONFIG_DATA', vmcLevel: 2 }
  const { client, calls } = createMockAdminClient({
    selectResult: {
      mdb_diagnostics: { state: 'DISABLED' },
      company: COMPANY_ID,
    },
  })

  const result = await handleMdbLog(encodePayload(payload), DEVICE_ID, client)

  assertEquals(result.status, 200)
  assertEquals(result.stateChanged, true)
  assertEquals(calls.inserts[0].data.vmc_level, 2)

  // Also verify vmcLevel is preserved in mdb_diagnostics via raw
  const raw = calls.inserts[0].data.raw as Record<string, unknown>
  assertEquals(raw.vmcLevel, 2)
})

Deno.test('mdb-log: missing vmcLevel results in null vmc_level (backward compat)', async () => {
  // Old firmware doesn't send vmcLevel
  const payload = { state: 'ENABLED', addr: '0x10', polls: 100, chkErr: 0, lastCmd: 'READER_ENABLE' }
  const { client, calls } = createMockAdminClient({
    selectResult: {
      mdb_diagnostics: { state: 'DISABLED' },
      company: COMPANY_ID,
    },
  })

  const result = await handleMdbLog(encodePayload(payload), DEVICE_ID, client)

  assertEquals(result.status, 200)
  assertEquals(calls.inserts[0].data.vmc_level, null)
})
```

**Step 2: Update the handleMdbLog helper in the test file**

The `handleMdbLog` function in the test file (lines 81-147) must also include the `vmc_level` mapping. Update the insert call inside `handleMdbLog` (around line 132-141):

```typescript
const { error: insertErr } = await adminClient
  .from('mdb_log')
  .insert({
    embedded_id: deviceId,
    state: newState,
    prev_state: prevState ?? null,
    addr: (diag.addr as string) ?? null,
    polls: (diag.polls as number) ?? null,
    chk_err: (diag.chkErr as number) ?? null,
    last_cmd: (diag.lastCmd as string) ?? null,
    vmc_level: (diag.vmcLevel as number) ?? null,
    raw: diag,
  })
```

**Step 3: Run tests**

```bash
cd Docker/supabase/functions
deno test mqtt-webhook/mdb-log.test.ts --allow-env
```

Expected: All tests pass (8 existing + 2 new = 10 total).

**Step 4: Commit**

```bash
git add Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts
git commit -m "test(webhook): add vmcLevel mapping and backward compat tests"
```

---

### Task 7: Frontend — Add vmcLevel to Composable and UI

**Files:**
- Modify: `management-frontend/app/composables/useMdbLog.ts:3-23` (interfaces)
- Modify: `management-frontend/app/pages/machines/[id].vue:1588` (grid layout)
- Modify: `management-frontend/i18n/locales/en.json:170` (i18n)
- Modify: `management-frontend/i18n/locales/de.json:170` (i18n)

**Step 1: Add vmcLevel to interfaces in useMdbLog.ts**

Add `vmcLevel` to `MdbDiagnostics` interface (after line 21):

```typescript
export interface MdbDiagnostics {
    state: string
    addr: string
    polls: number
    chkErr: number
    lastCmd: string
    vmcLevel?: number
    updated_at: string
}
```

Add `vmc_level` to `MdbLogEntry` interface (after line 12):

```typescript
export interface MdbLogEntry {
    id: string
    created_at: string
    embedded_id: string
    state: string
    prev_state: string | null
    addr: string | null
    polls: number | null
    chk_err: number | null
    last_cmd: string | null
    vmc_level: number | null
    raw: Record<string, unknown> | null
}
```

**Step 2: Add VMC Level to the current status card grid**

In `[id].vue`, update the grid at line 1588 from `lg:grid-cols-5` to `lg:grid-cols-6`:

```html
<div class="grid grid-cols-2 gap-3 sm:gap-4 sm:grid-cols-3 lg:grid-cols-6">
```

Then add a new VMC Level cell after the Address cell (after line 1606), before Polls:

```html
<div class="min-w-0">
  <p class="text-xs text-muted-foreground">{{ t('machineDetail.vmcLevel') }}</p>
  <p class="mt-1 text-sm font-medium">
    {{ machine.embeddeds.mdb_diagnostics.vmcLevel ? `Level ${machine.embeddeds.mdb_diagnostics.vmcLevel}` : '–' }}
  </p>
</div>
```

**Step 3: Add i18n keys**

In `management-frontend/i18n/locales/en.json`, add after `"lastCommand"` line (after line 170):

```json
"vmcLevel": "VMC Level",
```

In `management-frontend/i18n/locales/de.json`, add after `"lastCommand"` line (after line 170):

```json
"vmcLevel": "VMC-Level",
```

**Step 4: Commit**

```bash
git add management-frontend/app/composables/useMdbLog.ts management-frontend/app/pages/machines/[id].vue management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat(frontend): display VMC feature level in MDB diagnostics"
```

---

### Task 8: Verify Everything Works Together

**Step 1: Apply migration locally**

```bash
cd Docker/supabase
supabase migration up
```

**Step 2: Run edge function tests**

```bash
cd Docker/supabase/functions
deno test mqtt-webhook/mdb-log.test.ts --allow-env
```

Expected: 10 tests pass.

**Step 3: Build firmware (if ESP-IDF available)**

```bash
cd mdb-slave-esp32s3
. $IDF_PATH/export.sh
idf.py build
```

Expected: Clean build, no warnings.

**Step 4: Run frontend dev server**

```bash
cd management-frontend
npm run dev
```

Verify: MDB diagnostics tab shows "VMC Level" field (will show "–" until a device with new firmware reports).

**Step 5: Final commit if any fixes needed**

---

## File Change Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` | Modify | Store vmcFeatureLevel, adapt Begin Session, update diagnostics |
| `Docker/supabase/migrations/20260312000000_mdb_vmc_level.sql` | Create | Add nullable `vmc_level` column |
| `Docker/supabase/functions/mqtt-webhook/index.ts` | Modify | Map `vmcLevel` → `vmc_level` in insert |
| `Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts` | Modify | Add 2 test cases for vmcLevel |
| `management-frontend/app/composables/useMdbLog.ts` | Modify | Add vmcLevel to interfaces |
| `management-frontend/app/pages/machines/[id].vue` | Modify | Display VMC Level in status card |
| `management-frontend/i18n/locales/en.json` | Modify | Add vmcLevel i18n key |
| `management-frontend/i18n/locales/de.json` | Modify | Add vmcLevel i18n key |
