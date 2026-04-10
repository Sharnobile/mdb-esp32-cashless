# MDB Level 2/3 Support Design

**Date:** 2026-03-12
**Status:** Approved

## Problem

The ESP32 cashless slave always responds with MDB Level 1 format. When connected to a VMC that expects Level 2, the Begin Session response is 3 bytes instead of the expected 10 bytes. The VMC times out waiting for remaining bytes and never displays credit. Cancel (1 byte at all levels) works fine, confirming the root cause.

## MDB Spec Summary

### Begin Session (0x03) — the only response that differs

| Level | Format | Bytes |
|-------|--------|-------|
| 1 | `0x03 + funds(2)` | 3 |
| 2 | `0x03 + funds(2) + media_id(4) + payment_type(1) + payment_data(2)` | 10 |
| 3 standard | Same as Level 2 | 10 |
| 3 expanded | `0x03 + funds(4) + media_id(4) + payment_type(1) + payment_data(2) + language(2) + currency(2) + card_options(1)` | 17 |

Level 3 expanded mode requires VMC to explicitly enable feature bits via Expansion Enable Options (17H-04H). Since we don't process that sub-command, Level 3 = Level 2 format (10 bytes). This is spec-compliant.

### Responses identical across all levels

- Session Cancel (0x04): 1 byte
- Vend Approved (0x05): 3 bytes
- Vend Denied (0x06): 1 byte
- End Session (0x07): 1 byte
- Reader Config Data (0x01): 8 bytes (only Feature Level byte value changes)

## Changes

### 1. Firmware (`mdb-slave-esp32s3.c`)

**Store VMC Feature Level:**
- Add global `uint8_t vmc_feature_level = 1` (default Level 1)
- In SETUP CONFIG_DATA handler: store `vmcFeatureLevel` instead of `(void)` cast
- Determine reader level: `min(vmc_feature_level, 3)` — support up to Level 3

**Adapt Reader Config Data response:**
- Change `mdb_payload[1] = 1` to `mdb_payload[1] = min(vmc_feature_level, 3)`

**Adapt Begin Session response:**
- Level 1: 3 bytes (unchanged)
  - `0x03 | funds_high | funds_low`
- Level 2/3: 10 bytes
  - `0x03 | funds_high | funds_low | 0xFF 0xFF 0xFF 0xFF | 0x00 | 0x00 | 0x00`
  - Media ID = `0xFFFFFFFF` (no specific card)
  - Payment Type = `0x00` — top 2 bits `00` = normal vend card, bottom 6 bits `000000` = sub-type 0 "VMC default prices"
  - Payment Data = `0x0000` — undefined for sub-type 0, must be zero
    - **Earlier revision of this doc specified "copy of funds available" — that was wrong.** Echoing funds into Z9-Z10 causes strict VMCs to interpret the value as an out-of-range `xx000011b` "Discount percentage factor" (valid range 0..100), resulting in the session starting (bill validator disabled) but no credit displayed. See MDB/ICP Section 7.4 Begin Session payment data table.

**Add vmcLevel to diagnostics:**
- `publish_mdb_diag()`: add `"vmcLevel":<n>` to JSON payload
- Also add to serial log: `MDB DIAG: state=... vmcLevel=%d ...`

### 2. Backend (`mqtt-webhook` edge function)

**mdb-log handler updates:**
- Parse optional `vmcLevel` from mdb-log JSON
- Store in `embeddeds.mdb_diagnostics` JSONB (alongside existing fields)
- Store in `mdb_log.vmc_level` column (new, nullable)

### 3. Database Migration

New migration file:
```sql
ALTER TABLE public.mdb_log ADD COLUMN vmc_level smallint;
```

Nullable column — backward compatible. Old firmware without vmcLevel in payload results in NULL.

### 4. Frontend

**`useMdbLog.ts` composable:**
- Add `vmcLevel?: number` to `MdbDiagnostics` interface
- Add `vmc_level?: number` to `MdbLogEntry` interface

**Machine detail page (`[id].vue`):**
- Add "VMC Level" row to MDB diagnostics current status card
- Display: `Level 1`, `Level 2`, `Level 3`, or `–` (if null/unknown)

## Backward Compatibility

| Scenario | Behavior |
|----------|----------|
| Old firmware + new backend | mdb-log has no `vmcLevel` → `vmc_level` stays NULL |
| New firmware + Level 1 VMC | Slave responds with Level 1 format (3-byte Begin Session) |
| New firmware + Level 2 VMC | Slave responds with Level 2 format (10-byte Begin Session) |
| New firmware + Level 3 VMC | Slave responds with Level 2 format (10-byte Begin Session) — no expanded mode |
| New frontend + old firmware | Shows "–" for VMC Level |
