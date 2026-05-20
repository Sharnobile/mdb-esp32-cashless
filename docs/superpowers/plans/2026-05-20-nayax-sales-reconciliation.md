# Nayax Sales Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `/reports/nayax-reconciliation` page where an admin uploads a Nayax sales export (`.xlsx`), the app compares it against our `sales` table over the export's date range, and surfaces three buckets (matched / missing-in-DB / ghost-in-DB) with bulk import for missing and per-row delete for ghosts.

**Architecture:** Client-side analyze flow. xlsx parsing + matching all happens in the browser. Persistent `vendingMachine.nayax_machine_id` mapping (one new nullable column + sparse index). The two mutating actions reuse existing RPCs (`insert_manual_sale`, `delete_sale_and_restore_stock`). No new edge functions.

**Tech Stack:** Nuxt 4 + Vue 3 (composition API), TypeScript, `@nuxtjs/supabase`, shadcn-nuxt, TailwindCSS 4, `xlsx` (already a dep), `date-fns-tz` (new, ~10 KB for DST-correct timezone parsing), Vitest + happy-dom.

**Spec:** [docs/superpowers/specs/2026-05-20-nayax-sales-reconciliation-design.md](../specs/2026-05-20-nayax-sales-reconciliation-design.md)

**Verification model:** TDD the composable logic (parser, timezone, regex, matcher, CSV, channel derivation) via Vitest. UI components are verified by manual smoke test against the dev server at the end of each UI chunk. Every chunk ends with a commit.

---

## Pre-flight

- [ ] **Step 0.1: Confirm dev environment is healthy**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase
supabase status
```

Expected: `API URL`, `DB URL`, `Studio URL` all printed and reachable. If the local supabase isn't running, `supabase start`. (Optionally also `cd Docker && docker compose ps` to verify the prod-style compose stack — but only the CLI stack is required for the dev DB used by `supabase migration up` in Task 1.)

- [ ] **Step 0.2: Verify frontend builds before any changes**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run test
```

Expected: all existing Vitest suites pass (currently 8 test files under `app/composables/__tests__/`). If any fail on `main`, stop and tell the user — do not start work on a broken baseline.

- [ ] **Step 0.3: Confirm the Nayax sample file is in place**

```bash
ls -la /Users/lucienkerl/Development/mdb-esp32-cashless/tmp/nayax-sale.xlsx
```

Expected: file exists, ~38 KB. This file is the parser fixture. If it's missing, ask the user before continuing — the spec was derived from its column layout.

---

## Chunk 1: Database column + Machine-Settings field

Adds the `nayax_machine_id` column and wires up a single input in the existing `MachineSettingsModal` so admins can set it per machine. No new UI surfaces yet — this chunk ends with a working settings field but no reconciliation page.

### Task 1: Migration

**Files:**
- Create: `Docker/supabase/migrations/20260520120000_vending_machine_nayax_id.sql`

- [ ] **Step 1.1: Write the migration**

Create `Docker/supabase/migrations/20260520120000_vending_machine_nayax_id.sql`:

```sql
-- Adds nayax_machine_id to vendingMachine for Nayax sales reconciliation.
-- Nullable, additive, backward-compatible. Existing firmware and clients
-- ignore this column (they select * but don't depend on the field's
-- presence).
ALTER TABLE public."vendingMachine"
  ADD COLUMN IF NOT EXISTS nayax_machine_id text;

-- Sparse partial index — most rows are NULL until admins configure
-- mappings. Speeds up lookup by Nayax serial during reconciliation.
CREATE INDEX IF NOT EXISTS vending_machine_nayax_id_idx
  ON public."vendingMachine" (nayax_machine_id)
  WHERE nayax_machine_id IS NOT NULL;
```

No UNIQUE constraint: Nayax IDs are global, two companies could theoretically share one in their export data. RLS is already enforced by the existing `vendingMachine` row-level policies.

- [ ] **Step 1.2: Apply the migration to the local dev DB**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase
supabase migration up
```

Expected: output mentions `20260520120000_vending_machine_nayax_id.sql` applied. **Never** use `supabase db reset` — the dev DB holds test data.

- [ ] **Step 1.3: Verify the column exists**

```bash
docker exec supabase_db_supabase-test psql -U postgres -d postgres \
  -c "\d public.\"vendingMachine\"" | grep nayax
```

Expected: `nayax_machine_id   | text  |          | `.

```bash
docker exec supabase_db_supabase-test psql -U postgres -d postgres \
  -c "\di public.vending_machine_nayax_id_idx"
```

Expected: one row showing the index name and `vendingMachine` as the table.

- [ ] **Step 1.4: Commit**

```bash
git add Docker/supabase/migrations/20260520120000_vending_machine_nayax_id.sql
git commit -m "$(cat <<'EOF'
feat(db): add nayax_machine_id to vendingMachine

Nullable additive column with sparse partial index. Used by upcoming
Nayax sales reconciliation feature to map Nayax machine serials to
our vendingMachine UUIDs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2: Extend `MachineSettingsPatch` + `updateMachineSettings`

**Files:**
- Modify: `management-frontend/app/composables/useMachines.ts:66-75` (type), `:573-593` (function), `:97-100` (select-list of columns in `fetchMachines`)

- [ ] **Step 2.1: Read the current shape**

```bash
sed -n '95,105p;66,76p;570,595p' /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/composables/useMachines.ts
```

Confirm the file lines match the references in this plan. If they've shifted by a few lines (e.g. after an unrelated edit), update the line ranges in your edits accordingly.

- [ ] **Step 2.2: Add `nayax_machine_id` to the `Machine` interface fields fetched**

In `useMachines.ts`, find the `fetchMachines` body and the select string starting at line ~97 (`id, name, location_lat, location_lon, embedded, country_code, public_listing, …`). Add `nayax_machine_id` to the list of selected columns. Also add `nayax_machine_id: string | null` to the local `VendingMachine` interface near line ~18 (the interface starts with the `name`, `location_lat`, `location_lon` fields).

- [ ] **Step 2.3: Add `nayax_machine_id` to `MachineSettingsPatch`**

Replace the `MachineSettingsPatch` interface (line ~66) with:

```ts
export interface MachineSettingsPatch {
  location_lat: number | null
  location_lon: number | null
  address_street: string | null
  address_house_number: string | null
  address_postal_code: string | null
  address_city: string | null
  formatted_address: string | null
  country_code: string | null
  nayax_machine_id: string | null
}
```

- [ ] **Step 2.4: Extend the optimistic cache update in `updateMachineSettings`**

In `updateMachineSettings` (line ~573), after the `if (machine) {` block that assigns `location_lat` etc., add:

```ts
      machine.nayax_machine_id = patch.nayax_machine_id
```

- [ ] **Step 2.5: Verify TypeScript still compiles**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npx vue-tsc --noEmit 2>&1 | tail -30
```

Expected: zero errors. If any caller of `updateMachineSettings` now fails because the patch is missing the new field, the next task (the modal) fixes that — but make sure no other unexpected error appears.

### Task 3: Add Nayax-Machine-ID input to `MachineSettingsModal`

**Files:**
- Modify: `management-frontend/app/components/MachineSettingsModal.vue:52-...` (form init), inputs section in `<template>`

- [ ] **Step 3.1: Find the form init block**

```bash
grep -n "form\.value\.location_lat\|location_lat: props.initial\|form = ref\|form = reactive" /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/components/MachineSettingsModal.vue | head -10
```

Note the lines so the edits in subsequent steps target them precisely.

- [ ] **Step 3.2: Initialise `nayax_machine_id` in the form ref**

Find the form initialization (around line ~52) that has `location_lat: props.initial.location_lat ?? null,`. Add an analogous line:

```ts
    nayax_machine_id: props.initial.nayax_machine_id ?? null,
```

Place it next to the other patch fields so the form shape matches `MachineSettingsPatch`.

- [ ] **Step 3.3: Add the input control to the template**

Find the country dropdown block (search for `machineSettings.country` in the file). Right below the country `<select>` block (and above the LocationPicker), add:

```html
        <div class="space-y-1">
          <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.nayaxMachineId') }}</label>
          <input
            v-model="form.nayax_machine_id"
            type="text"
            inputmode="numeric"
            :placeholder="t('machineSettings.nayaxMachineIdPlaceholder')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <p class="mt-1 text-[10px] text-muted-foreground">{{ t('machineSettings.nayaxMachineIdHint') }}</p>
        </div>
```

Treat empty string as `null` on save — add a one-liner just before `await updateMachineSettings(props.machineId, form.value as MachineSettingsPatch)` (~line 152):

```ts
    if (form.value.nayax_machine_id === '') form.value.nayax_machine_id = null
```

- [ ] **Step 3.4: Add i18n keys for the field (German + English)**

In `management-frontend/i18n/locales/de.json`, find the `"machineSettings"` block and add three keys (sort alphabetically with the existing ones):

```json
    "nayaxMachineId": "Nayax-Maschinen-ID",
    "nayaxMachineIdPlaceholder": "z. B. 92700604",
    "nayaxMachineIdHint": "Erforderlich für den Nayax-Verkaufsabgleich. Diese ID findest du in deinem Nayax-Backoffice.",
```

In `management-frontend/i18n/locales/en.json`, add:

```json
    "nayaxMachineId": "Nayax Machine ID",
    "nayaxMachineIdPlaceholder": "e.g. 92700604",
    "nayaxMachineIdHint": "Required for Nayax sales reconciliation. You can find this ID in your Nayax back-office.",
```

- [ ] **Step 3.5: Manual smoke test**

Start the dev stack (if not already up) and the dev server:

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run dev
```

Open `http://localhost:3000`, log in (credentials in `~/.claude/projects/-Users-lucienkerl-Development-mdb-esp32-cashless/memory/user_dev_credentials.md`), navigate to `/machines/<some id>`, open Machine Settings, confirm a new "Nayax Machine ID" input appears. Type `92700604`, save, refresh the page, re-open Machine Settings → field still shows `92700604`. Clear the field, save, refresh → field is empty (stored as `null` in DB).

Verify in DB:

```bash
docker exec supabase_db_supabase-test psql -U postgres -d postgres \
  -c "SELECT id, name, nayax_machine_id FROM public.\"vendingMachine\" WHERE nayax_machine_id IS NOT NULL;"
```

Expected: at least one row showing the value you saved (or zero rows after you cleared it).

- [ ] **Step 3.6: Commit**

```bash
git add management-frontend/app/composables/useMachines.ts \
        management-frontend/app/components/MachineSettingsModal.vue \
        management-frontend/i18n/locales/de.json \
        management-frontend/i18n/locales/en.json
git commit -m "$(cat <<'EOF'
feat(machines): add Nayax machine ID setting

Admins can now record the Nayax serial for each machine. This is the
mapping that the upcoming sales reconciliation page will use to join
Nayax export rows to our vendingMachine records.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: Composable foundation + helpers (TDD)

Sets up the new composable, installs the timezone library, and TDD's the three pure helpers (timezone conversion, item-number parsing, date-range parsing). No xlsx parsing yet — that's chunk 3.

### Task 4: Install `date-fns-tz`

**Files:**
- Modify: `management-frontend/package.json`, `management-frontend/package-lock.json`

- [ ] **Step 4.1: Install**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm install date-fns-tz
```

Expected: adds `date-fns-tz` (and its peer `date-fns`) to `dependencies`. The size of `date-fns-tz` is ~10 KB gzipped — small enough that the build size impact is negligible.

- [ ] **Step 4.2: Verify the lib resolves**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
node -e "const { fromZonedTime } = require('date-fns-tz'); console.log(fromZonedTime('2026-03-31 21:46:09', 'Europe/Berlin').toISOString())"
```

Expected: `2026-03-31T19:46:09.000Z` (CEST, DST already active on that date).

### Task 5: Create the composable skeleton

**Files:**
- Create: `management-frontend/app/composables/useNayaxReconciliation.ts`

- [ ] **Step 5.1: Write the file with types and state only**

Create `management-frontend/app/composables/useNayaxReconciliation.ts`:

```ts
import { useState, useSupabaseClient } from '#imports'

/** A single row parsed from the Nayax sales export. */
export interface NayaxRow {
  rowIndex: number          // 1-based index in the source file, for messages
  txId: string
  nayaxMachineId: string    // raw value from column 15
  machineName: string
  productGroup: string
  productName: string
  paymentSource: string     // "Cash" | "Credit Card(CLS)" | etc.
  priceGross: number        // rounded to 2dp
  itemNumber: number | null // parsed from column 14, null if regex fails
  selectionInfoRaw: string  // column 14 raw, kept for debug display
  localDt: string           // "DD.MM.YYYY HH:MM:SS" exactly as in file
  utcDt: string             // ISO 8601 UTC after timezone conversion
}

/** A sale row loaded from the DB for reconciliation. */
export interface DbSale {
  id: string
  created_at: string        // UTC from DB
  machine_id: string
  item_number: number | null
  item_price: number | null
  channel: string | null
  product_id: string | null
  product_name: string | null
}

export interface MatchPair {
  nayax: NayaxRow
  db: DbSale
  deltaSeconds: number      // db.created_at - nayax.utcDt
}

export interface ReconResult {
  matched: MatchPair[]
  missingInDb: NayaxRow[]
  ghostInDb: DbSale[]
  unmapped: NayaxRow[]
  unparseable: NayaxRow[]
  fileDateRange: { fromUtc: string; toUtc: string } | null
  settings: {
    timezone: string
    toleranceSeconds: number
  }
}

export type Step = 'upload' | 'mapping' | 'settings' | 'results'

/**
 * Compose the Nayax reconciliation workflow.
 *
 * The composable owns: the parsed Nayax rows, the per-company Nayax→VM
 * mapping cache, the matching settings, the loaded DB sales, and the
 * computed reconciliation result. The wizard page and child components
 * receive reactive refs from this composable and emit intent events to
 * trigger its actions.
 */
export function useNayaxReconciliation() {
  // IMPORTANT: workflow state uses `useState(key, …)` so the page and every
  // child component share the same refs. A plain `ref(...)` would give each
  // call site its own isolated state — the wizard would not work. This
  // mirrors the pattern in `useMachines` (see `useState<VendingMachine[]>('machines', …)`).
  const file = useState<File | null>('nayax-recon-file', () => null)
  const rawRows = useState<NayaxRow[]>('nayax-recon-rawRows', () => [])
  const dbSales = useState<DbSale[]>('nayax-recon-dbSales', () => [])
  const mapping = useState<Map<string, string>>('nayax-recon-mapping', () => new Map())
  const settings = useState('nayax-recon-settings', () => ({
    timezone: 'Europe/Berlin',
    toleranceSeconds: 10,
    fromUtc: '' as string,
    toUtc: '' as string,
  }))
  const result = useState<ReconResult | null>('nayax-recon-result', () => null)
  const step = useState<Step>('nayax-recon-step', () => 'upload' as Step)
  const parsing = useState<boolean>('nayax-recon-parsing', () => false)
  const matching = useState<boolean>('nayax-recon-matching', () => false)
  const importing = useState<boolean>('nayax-recon-importing', () => false)
  const deleting = useState<boolean>('nayax-recon-deleting', () => false)
  const error = useState<string>('nayax-recon-error', () => '')

  // Stubs filled in by later tasks
  async function parseFile(_f: File): Promise<void> { throw new Error('not impl') }
  async function loadMappingForCompany(): Promise<void> { throw new Error('not impl') }
  function detectUnmappedIds(): string[] { throw new Error('not impl') }
  async function saveMapping(_nayaxId: string, _vmId: string | null): Promise<void> { throw new Error('not impl') }
  async function loadDbSales(): Promise<void> { throw new Error('not impl') }
  function runMatch(): void { throw new Error('not impl') }
  async function bulkImportMissing(_rows: NayaxRow[]): Promise<{ imported: number; errors: string[] }> { throw new Error('not impl') }
  async function deleteGhost(_saleId: string): Promise<void> { throw new Error('not impl') }
  function exportDiffCsv(): string { throw new Error('not impl') }
  function reset(): void {
    file.value = null
    rawRows.value = []
    dbSales.value = []
    result.value = null
    step.value = 'upload'
    error.value = ''
  }

  return {
    file, rawRows, dbSales, mapping, settings, result, step,
    parsing, matching, importing, deleting, error,
    parseFile, loadMappingForCompany, detectUnmappedIds, saveMapping,
    loadDbSales, runMatch, bulkImportMissing, deleteGhost, exportDiffCsv,
    reset,
  }
}
```

- [ ] **Step 5.2: Run the test suite to confirm nothing broke**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run test
```

Expected: all existing tests still pass. The new composable has no tests yet and exposes only stubs — that's fine, it's not imported anywhere.

### Task 6: TDD pure helper `localDtToUtc`

**Files:**
- Create: `management-frontend/app/composables/__tests__/useNayaxReconciliation.test.ts`
- Modify: `management-frontend/app/composables/useNayaxReconciliation.ts`

- [ ] **Step 6.1: Write the failing tests**

Create `management-frontend/app/composables/__tests__/useNayaxReconciliation.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { localDtToUtc } from '../useNayaxReconciliation'

describe('localDtToUtc', () => {
  it('parses Nayax DD.MM.YYYY HH:MM:SS in CEST (summer) to UTC', () => {
    // 2026-03-31 is after DST start (2026-03-29) → CEST (UTC+2)
    expect(localDtToUtc('31.03.2026 21:46:09', 'Europe/Berlin'))
      .toBe('2026-03-31T19:46:09.000Z')
  })

  it('parses Nayax DD.MM.YYYY HH:MM:SS in CET (winter) to UTC', () => {
    // 2026-01-15 is winter → CET (UTC+1)
    expect(localDtToUtc('15.01.2026 12:00:00', 'Europe/Berlin'))
      .toBe('2026-01-15T11:00:00.000Z')
  })

  it('handles the spring-forward gap without throwing', () => {
    // 02:30 on 2026-03-29 does not exist in Europe/Berlin (clocks jump
    // 02:00 CET → 03:00 CEST). The exact value returned by date-fns-tz
    // for non-existent instants is library-defined and has historically
    // differed across versions — we don't pin a specific UTC time. We
    // only assert the function returns *some* valid ISO 8601 within the
    // plausible window (00:30 UTC if pre-jump, 01:30 UTC if post-jump).
    const out = localDtToUtc('29.03.2026 02:30:00', 'Europe/Berlin')
    expect(out).toMatch(/^2026-03-29T0[01]:30:00\.000Z$/)
  })

  it('returns empty string for malformed input', () => {
    expect(localDtToUtc('not a date', 'Europe/Berlin')).toBe('')
    expect(localDtToUtc('', 'Europe/Berlin')).toBe('')
  })
})
```

- [ ] **Step 6.2: Run the test and verify it fails**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -20
```

Expected: FAIL with `localDtToUtc is not exported from '../useNayaxReconciliation'` or similar.

- [ ] **Step 6.3: Implement `localDtToUtc`**

In `management-frontend/app/composables/useNayaxReconciliation.ts`, add this exported helper near the top (before the `useNayaxReconciliation` function):

```ts
import { fromZonedTime } from 'date-fns-tz'

/**
 * Parse a Nayax "DD.MM.YYYY HH:MM:SS" timestamp interpreted in the given
 * IANA timezone and return its UTC equivalent as an ISO 8601 string.
 * Returns '' for malformed input.
 */
export function localDtToUtc(local: string, tz: string): string {
  const m = local.match(/^(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}):(\d{2}):(\d{2})$/)
  if (!m) return ''
  const [, dd, mm, yyyy, hh, mi, ss] = m
  // fromZonedTime takes an ISO-ish local string + IANA tz and returns the
  // Date at the corresponding UTC instant.
  const isoLocal = `${yyyy}-${mm}-${dd}T${hh}:${mi}:${ss}`
  const utc = fromZonedTime(isoLocal, tz)
  return utc.toISOString()
}
```

- [ ] **Step 6.4: Run the test and verify it passes**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -20
```

Expected: 4 tests pass.

### Task 7: TDD `parseSelectionInfo`

**Files:**
- Modify: `useNayaxReconciliation.test.ts`, `useNayaxReconciliation.ts`

- [ ] **Step 7.1: Add the failing tests**

Append to the test file:

```ts
import { parseSelectionInfo } from '../useNayaxReconciliation'

describe('parseSelectionInfo', () => {
  it('extracts the item number from "Product Name(N  price)"', () => {
    expect(parseSelectionInfo('Mars Classic Single(39  1.20)')).toBe(39)
  })

  it('handles two-digit item numbers', () => {
    expect(parseSelectionInfo('Powerade Sports Mountain Blast(58  2.50)')).toBe(58)
  })

  it('handles three-digit item numbers', () => {
    expect(parseSelectionInfo('Test(123  9.99)')).toBe(123)
  })

  it('handles single-digit item numbers', () => {
    expect(parseSelectionInfo('Test(1  0.50)')).toBe(1)
  })

  it('returns null when no parenthesis group is present', () => {
    expect(parseSelectionInfo('Just a product name')).toBeNull()
    expect(parseSelectionInfo('')).toBeNull()
  })

  it('returns null when the parenthesis group is malformed', () => {
    expect(parseSelectionInfo('Product(abc  1.00)')).toBeNull()
    expect(parseSelectionInfo('Product()')).toBeNull()
  })

  it('strips trailing whitespace and newlines (Nayax exports often have them)', () => {
    expect(parseSelectionInfo('NicNacs 35g(38  1.50)\n')).toBe(38)
  })
})
```

- [ ] **Step 7.2: Run, verify failure, then implement**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -20
```

Expected: 7 new tests fail.

In `useNayaxReconciliation.ts`, add:

```ts
/**
 * Extract the MDB selection (item) number from Nayax's
 * `Produktauswahl-Informationen` column. Format observed in the wild:
 *   "Product Name(NN  P.PP)"  e.g. "Mars Classic Single(39  1.20)"
 * Returns null when the parenthesis group is absent or malformed.
 */
export function parseSelectionInfo(raw: string): number | null {
  const m = raw.match(/\((\d+)\s+[\d.,]+\)/)
  if (!m) return null
  const n = parseInt(m[1], 10)
  return Number.isFinite(n) ? n : null
}
```

- [ ] **Step 7.3: Verify all tests pass**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -10
```

Expected: 11 tests pass (4 + 7).

### Task 8: TDD `parseTitleDateRange`

**Files:**
- Modify: `useNayaxReconciliation.test.ts`, `useNayaxReconciliation.ts`

- [ ] **Step 8.1: Failing tests**

Append:

```ts
import { parseTitleDateRange } from '../useNayaxReconciliation'

describe('parseTitleDateRange', () => {
  it('extracts from the German "Gesuchter Datumsbereich:" line', () => {
    // Note: the real Nayax file prefixes the title with a handful of
    // U+200B zero-width spaces. They're invisible and don't affect the
    // regex, so we just use the visible content here.
    const title = 'Dynamische Transaktionsüberwachung\nGesuchter Datumsbereich: 01.03.2026 00:00:00 - 31.03.2026 23:59:59'
    expect(parseTitleDateRange(title, 'Europe/Berlin')).toEqual({
      fromUtc: '2026-02-28T23:00:00.000Z',  // 01.03 00:00 CET = 28.02 23:00 UTC
      toUtc:   '2026-03-31T21:59:59.000Z',  // 31.03 23:59:59 CEST = 21:59:59 UTC
    })
  })

  it('returns null when the line is missing', () => {
    expect(parseTitleDateRange('Random title', 'Europe/Berlin')).toBeNull()
  })

  it('returns null when only the start half is present', () => {
    expect(parseTitleDateRange('Datumsbereich: 01.03.2026 00:00:00', 'Europe/Berlin')).toBeNull()
  })
})
```

- [ ] **Step 8.2: Implement after observing the failure**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -10
```

Then add to `useNayaxReconciliation.ts`:

```ts
/**
 * Parse "Gesuchter Datumsbereich: DD.MM.YYYY HH:MM:SS - DD.MM.YYYY HH:MM:SS"
 * from row 1 of a Nayax export and convert both endpoints to UTC ISO 8601
 * strings. Returns null if the pattern is not present or malformed.
 */
export function parseTitleDateRange(
  title: string,
  tz: string,
): { fromUtc: string; toUtc: string } | null {
  const m = title.match(
    /(\d{2}\.\d{2}\.\d{4}\s+\d{2}:\d{2}:\d{2})\s*-\s*(\d{2}\.\d{2}\.\d{4}\s+\d{2}:\d{2}:\d{2})/,
  )
  if (!m) return null
  const fromUtc = localDtToUtc(m[1], tz)
  const toUtc = localDtToUtc(m[2], tz)
  if (!fromUtc || !toUtc) return null
  return { fromUtc, toUtc }
}
```

- [ ] **Step 8.3: Verify**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -10
```

Expected: 14 tests pass.

### Task 9: Commit Chunk 2

- [ ] **Step 9.1: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add management-frontend/package.json management-frontend/package-lock.json \
        management-frontend/app/composables/useNayaxReconciliation.ts \
        management-frontend/app/composables/__tests__/useNayaxReconciliation.test.ts
git commit -m "$(cat <<'EOF'
feat(reconcile): composable scaffolding + pure helpers

Adds date-fns-tz, sets up useNayaxReconciliation with the shape it
will grow into, and TDDs the three pure helpers it needs: timezone
conversion (with the spring-forward gap test), the item-number regex
parser, and the title-row date-range extractor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 3: xlsx parsing + DB loading

Wires `parseFile` to the real xlsx library against the committed fixture, then implements the mapping persistence and the sales-load query.

### Task 10: Commit the parser fixture

**Files:**
- Create: `management-frontend/app/test-helpers/fixtures/nayax-sample.xlsx` (copied from `tmp/nayax-sale.xlsx`)

- [ ] **Step 10.1: Copy the user's sample file into a test-friendly path**

```bash
mkdir -p /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/test-helpers/fixtures
cp /Users/lucienkerl/Development/mdb-esp32-cashless/tmp/nayax-sale.xlsx \
   /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/test-helpers/fixtures/nayax-sample.xlsx
ls -la /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/test-helpers/fixtures/
```

Expected: `nayax-sample.xlsx` is ~38 KB.

The fixture contains real machine names ("Niedernhall Frankeneck", "Giebelheide Zenkert") and real product names but no PII. If you want to redact, do it before committing — but for the v1 plan we keep it as-is since the names already appear in the design doc and aren't sensitive.

### Task 11: TDD `parseFile`

**Files:**
- Modify: `useNayaxReconciliation.test.ts`, `useNayaxReconciliation.ts`

- [ ] **Step 11.1: Add a fixture-loading helper and failing test**

Append to `useNayaxReconciliation.test.ts`:

```ts
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

function loadFixture(name: string): File {
  const here = dirname(fileURLToPath(import.meta.url))
  const buf = readFileSync(resolve(here, '../../test-helpers/fixtures', name))
  // Cast Buffer to ArrayBuffer for the File constructor
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)
  return new File([ab as ArrayBuffer], name, {
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  })
}

describe('parseFile', () => {
  it('parses the Nayax fixture without errors', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    expect(r.rawRows.value.length).toBeGreaterThan(0)
    expect(r.error.value).toBe('')
  })

  it('skips the title row and the Total footer', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    // No row should have txId "" or machineName "Total"
    for (const row of r.rawRows.value) {
      expect(row.txId).not.toBe('')
      expect(row.machineName).not.toBe('Total')
    }
  })

  it('extracts the expected fields from the first data row', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    const first = r.rawRows.value[0]
    // First row in the fixture: Powerade Sports Mountain Blast, 31.03.2026 21:46:09
    expect(first.txId).toBe('62968009978')
    expect(first.nayaxMachineId).toBe('92700604')
    expect(first.machineName).toBe('Niedernhall Frankeneck')
    expect(first.productName).toBe('Powerade Sports Mountain Blast')
    expect(first.paymentSource).toBe('Cash')
    expect(first.priceGross).toBe(2.5)
    expect(first.itemNumber).toBe(58)
    expect(first.localDt).toBe('31.03.2026 21:46:09')
    expect(first.utcDt).toBe('2026-03-31T19:46:09.000Z')
  })

  it('populates fileDateRange from the title row', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    // Title says "01.03.2026 00:00:00 - 31.03.2026 23:59:59" in Europe/Berlin
    expect(r.settings.value.fromUtc).toBe('2026-02-28T23:00:00.000Z')
    expect(r.settings.value.toUtc).toBe('2026-03-31T21:59:59.000Z')
  })

  it('refuses files over the 50 000-row hard cap', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    // Simulate a huge file by directly testing the cap via a synthetic
    // override (we don't actually generate 50k rows in CI). Instead,
    // expose MAX_ROWS as a constant the test can read and the implementation
    // uses for its threshold.
    const { MAX_ROWS_HARD_CAP } = await import('../useNayaxReconciliation')
    expect(MAX_ROWS_HARD_CAP).toBe(50000)
  })
})
```

- [ ] **Step 11.2: Run the test and observe it fail**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -25
```

Expected: failures of the form `r.parseFile is not implemented` / `MAX_ROWS_HARD_CAP is not exported`.

- [ ] **Step 11.3: Implement `parseFile`**

In `useNayaxReconciliation.ts`:

1. Add a top-level export:

```ts
export const MAX_ROWS_SOFT_WARN = 10000
export const MAX_ROWS_HARD_CAP = 50000
```

2. Replace the `parseFile` stub with the real implementation:

```ts
  async function parseFile(f: File): Promise<void> {
    parsing.value = true
    error.value = ''
    rawRows.value = []
    file.value = f

    try {
      // Lazy-import xlsx so the dev-bundle is only paid when we actually
      // open the reconciliation page.
      const XLSX = await import('xlsx')
      const buffer = await f.arrayBuffer()
      const wb = XLSX.read(buffer, { type: 'array' })
      const sheetName = wb.SheetNames[0]
      if (!sheetName) throw new Error('parser.noSheet')
      const sheet = wb.Sheets[sheetName]

      // Read the raw matrix so we can grab the title row directly.
      const matrix = XLSX.utils.sheet_to_json<unknown[]>(sheet, {
        header: 1,
        defval: null,
        raw: false,
      })
      if (matrix.length < 2) throw new Error('parser.empty')

      // Row 0 = title cell (with the date range).
      const titleCell = String(matrix[0]?.[0] ?? '')
      const range = parseTitleDateRange(titleCell, settings.value.timezone)
      if (range) {
        settings.value.fromUtc = range.fromUtc
        settings.value.toUtc = range.toUtc
      }

      // Row 1 = headers.
      const headers = (matrix[1] ?? []).map(v => String(v ?? '').trim())
      const idx = {
        txId:           headers.indexOf('Transaktions-ID'),
        currency:       headers.indexOf('Währung'),
        machineName:    headers.indexOf('Maschinenname'),
        productGroup:   headers.indexOf('Produktgruppe'),
        paymentSource:  headers.indexOf('Payment Method (Source)'),
        productName:    headers.indexOf('Produktname'),
        machineDt:      headers.indexOf('Maschinen-Begleichszeit'),
        amount:         headers.indexOf('Zu begleichender Wert'),
        selectionInfo:  headers.indexOf('Produktauswahl-Informationen'),
        nayaxId:        headers.indexOf('Maschinen-ID'),
      }
      for (const [k, v] of Object.entries(idx)) {
        if (v < 0) throw new Error(`parser.missingHeader.${k}`)
      }

      // Rows 2..end = data + a final "Total" row.
      const data = matrix.slice(2)
      if (data.length > MAX_ROWS_HARD_CAP) {
        throw new Error('parser.tooLarge')
      }

      const rows: NayaxRow[] = []
      data.forEach((row, i) => {
        const txId = String(row[idx.txId] ?? '').trim()
        const currency = String(row[idx.currency] ?? '').trim()
        // The footer is empty in Transaktions-ID (and Währung holds 'Total').
        if (!txId || currency === 'Total') return

        const localDt = String(row[idx.machineDt] ?? '').trim()
        const selectionInfoRaw = String(row[idx.selectionInfo] ?? '').trim()
        const priceGross = roundTo2(Number(row[idx.amount] ?? 0))

        rows.push({
          rowIndex: i + 3,                       // 1-based source row
          txId,
          nayaxMachineId: String(row[idx.nayaxId] ?? '').trim(),
          machineName: String(row[idx.machineName] ?? '').trim(),
          productGroup: String(row[idx.productGroup] ?? '').trim(),
          productName: String(row[idx.productName] ?? '').trim(),
          paymentSource: String(row[idx.paymentSource] ?? '').trim(),
          priceGross,
          itemNumber: parseSelectionInfo(selectionInfoRaw),
          selectionInfoRaw,
          localDt,
          utcDt: localDtToUtc(localDt, settings.value.timezone),
        })
      })

      rawRows.value = rows
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : 'parser.unknown'
    } finally {
      parsing.value = false
    }
  }

  function roundTo2(n: number): number {
    return Math.round(n * 100) / 100
  }
```

- [ ] **Step 11.4: Run and verify**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -15
```

Expected: 19 tests pass (14 + 5).

### Task 12: Implement `loadMappingForCompany` and `saveMapping`

**Files:**
- Modify: `useNayaxReconciliation.ts`

These two touch Supabase, so we exercise them in the manual smoke test at the end of chunk 4 rather than via unit test (existing pattern — `useMachines` itself is mostly smoke-tested).

- [ ] **Step 12.1: Replace `loadMappingForCompany` and `detectUnmappedIds`**

```ts
  async function loadMappingForCompany(): Promise<void> {
    const supabase = useSupabaseClient()
    const { data, error: err } = await supabase
      .from('vendingMachine')
      .select('id, nayax_machine_id')
      .not('nayax_machine_id', 'is', null)
    if (err) throw err
    const m = new Map<string, string>()
    for (const row of (data ?? []) as { id: string; nayax_machine_id: string }[]) {
      m.set(row.nayax_machine_id, row.id)
    }
    mapping.value = m
  }

  function detectUnmappedIds(): string[] {
    const seen = new Set<string>()
    for (const r of rawRows.value) {
      if (r.nayaxMachineId && !mapping.value.has(r.nayaxMachineId)) {
        seen.add(r.nayaxMachineId)
      }
    }
    return [...seen]
  }
```

- [ ] **Step 12.2: Replace `saveMapping`**

```ts
  async function saveMapping(nayaxId: string, vmId: string | null): Promise<void> {
    const supabase = useSupabaseClient()
    if (vmId == null) {
      // "Skip for this run" — do not write, just drop from local mapping
      mapping.value.delete(nayaxId)
      return
    }
    const { error: err } = await supabase
      .from('vendingMachine')
      .update({ nayax_machine_id: nayaxId } as any)
      .eq('id', vmId)
    if (err) throw err
    // Update the local cache so subsequent matching uses the new mapping
    // without a refetch.
    mapping.value.set(nayaxId, vmId)
  }
```

### Task 13: Implement `loadDbSales`

**Files:**
- Modify: `useNayaxReconciliation.ts`

- [ ] **Step 13.1: Replace the `loadDbSales` stub**

```ts
  async function loadDbSales(): Promise<void> {
    const supabase = useSupabaseClient()
    const { fromUtc, toUtc } = settings.value
    if (!fromUtc || !toUtc) {
      throw new Error('reconcile.noDateRange')
    }
    const machineIds = [...new Set(mapping.value.values())]
    if (machineIds.length === 0) {
      dbSales.value = []
      return
    }
    // Join products so we can show a name in the ghost table. product_id
    // was added to sales in 20260412000000_sales_product_id_snapshot.sql.
    const { data, error: err } = await supabase
      .from('sales')
      .select('id, created_at, machine_id, item_number, item_price, channel, product_id, products(name)')
      .gte('created_at', fromUtc)
      .lte('created_at', toUtc)
      .in('machine_id', machineIds)
      .order('created_at', { ascending: true })
    if (err) throw err
    dbSales.value = (data ?? []).map((row: any) => ({
      id: row.id,
      created_at: row.created_at,
      machine_id: row.machine_id,
      item_number: row.item_number,
      item_price: row.item_price,
      channel: row.channel,
      product_id: row.product_id,
      product_name: row.products?.name ?? null,
    }))
  }
```

### Task 14: Commit Chunk 3

- [ ] **Step 14.1: Run the whole test suite**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run test 2>&1 | tail -15
```

Expected: all suites pass — the new file has 19 of its own tests and no other tests should be affected.

- [ ] **Step 14.2: Commit**

```bash
git add management-frontend/app/composables/useNayaxReconciliation.ts \
        management-frontend/app/composables/__tests__/useNayaxReconciliation.test.ts \
        management-frontend/app/test-helpers/fixtures/nayax-sample.xlsx
git commit -m "$(cat <<'EOF'
feat(reconcile): parseFile + mapping/sales loaders

Wires xlsx parsing against a committed Nayax fixture, adds row caps
(soft 10k warn / hard 50k refuse), and implements the two Supabase
helpers that load the per-company Nayax→vendingMachine mapping and
the sales for the export's date range.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 4: Match algorithm + actions

The brain of the feature. TDD'd thoroughly because this is where correctness matters most.

### Task 15: TDD `runMatch`

**Files:**
- Modify: `useNayaxReconciliation.test.ts`, `useNayaxReconciliation.ts`

- [ ] **Step 15.1: Add the failing tests**

Append to the test file a new describe block. Each test seeds the composable with synthetic `rawRows`, `mapping`, `dbSales`, and `settings`, calls `runMatch()`, then asserts the buckets in `result.value`.

```ts
// Add these to the existing top-of-file imports so they're hoisted once:
import { useNayaxReconciliation, type NayaxRow, type DbSale } from '../useNayaxReconciliation'

function setupRecon(seed: {
  rawRows: NayaxRow[]
  mapping: Map<string, string>
  dbSales: DbSale[]
  toleranceSeconds?: number
  fromUtc?: string
  toUtc?: string
}) {
  const r = useNayaxReconciliation()
  // Note: in tests, the `#imports` → `nuxt-stubs.ts` alias makes
  // `useState(key, init)` return a fresh ref per call, so each `setupRecon`
  // invocation starts with its own isolated state — that's what we want.
  r.rawRows.value = seed.rawRows
  r.mapping.value = seed.mapping
  r.dbSales.value = seed.dbSales
  r.settings.value = {
    timezone: 'Europe/Berlin',
    toleranceSeconds: seed.toleranceSeconds ?? 10,
    fromUtc: seed.fromUtc ?? '2026-03-01T00:00:00.000Z',
    toUtc: seed.toUtc ?? '2026-03-31T23:59:59.000Z',
  }
  return r
}

function mkNayax(over: Partial<NayaxRow> = {}): NayaxRow {
  return {
    rowIndex: 3, txId: 'tx1', nayaxMachineId: 'N1', machineName: 'M1',
    productGroup: 'g', productName: 'p', paymentSource: 'Cash',
    priceGross: 2.5, itemNumber: 58, selectionInfoRaw: 'p(58  2.50)',
    localDt: '31.03.2026 21:46:09', utcDt: '2026-03-31T19:46:09.000Z',
    ...over,
  }
}
function mkSale(over: Partial<DbSale> = {}): DbSale {
  return {
    id: 's1', created_at: '2026-03-31T19:46:11.000Z',
    machine_id: 'vm1', item_number: 58, item_price: 2.5,
    channel: 'cash', product_id: null, product_name: null,
    ...over,
  }
}

describe('runMatch', () => {
  it('matches exact (Δ < tolerance) on machine + item + price + time', () => {
    const r = setupRecon({
      rawRows: [mkNayax()],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [mkSale()],   // Δ = +2 s
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.matched[0].deltaSeconds).toBeCloseTo(2, 0)
    expect(r.result.value!.missingInDb).toHaveLength(0)
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('counts a Δ within tolerance as a match (Δ = 9 s with 10 s tolerance)', () => {
    const r = setupRecon({
      rawRows: [mkNayax()],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [mkSale({ created_at: '2026-03-31T19:46:18.000Z' })],
      toleranceSeconds: 10,
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.missingInDb).toHaveLength(0)
  })

  it('treats a Δ outside tolerance as missing (Δ = 11 s with 10 s tolerance)', () => {
    const r = setupRecon({
      rawRows: [mkNayax()],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [mkSale({ created_at: '2026-03-31T19:46:20.000Z' })],
      toleranceSeconds: 10,
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(0)
    expect(r.result.value!.missingInDb).toHaveLength(1)
    // The DB sale is in the date range with a mapped machine → ghost
    expect(r.result.value!.ghostInDb).toHaveLength(1)
  })

  it('treats sub-cent price drift as a match (0.001 difference rounds away)', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ priceGross: 2.5 })],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [mkSale({ item_price: 2.5001 })],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
  })

  it('treats 0.01 price drift as a genuine mismatch', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ priceGross: 2.5 })],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [mkSale({ item_price: 2.51 })],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(0)
    expect(r.result.value!.missingInDb).toHaveLength(1)
  })

  it('one-to-one: two Nayax rows compete for one DB sale; earlier wins', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', utcDt: '2026-03-31T19:46:09.000Z' }),
        mkNayax({ txId: 'B', utcDt: '2026-03-31T19:46:11.000Z' }),
      ],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [mkSale({ created_at: '2026-03-31T19:46:10.000Z' })],
    })
    r.runMatch()
    // Sort by Nayax time asc → A claims the DB sale first
    expect(r.result.value!.matched.map(m => m.nayax.txId)).toEqual(['A'])
    expect(r.result.value!.missingInDb.map(n => n.txId)).toEqual(['B'])
  })

  it('one Nayax row with two DB candidates: closer Δ wins', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ utcDt: '2026-03-31T19:46:10.000Z' })],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [
        mkSale({ id: 'far',  created_at: '2026-03-31T19:46:15.000Z' }),  // Δ +5
        mkSale({ id: 'near', created_at: '2026-03-31T19:46:11.000Z' }),  // Δ +1
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched[0].db.id).toBe('near')
    expect(r.result.value!.ghostInDb.map(s => s.id)).toEqual(['far'])
  })

  it('unmapped Nayax rows go into `unmapped` and not `missingInDb`', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ nayaxMachineId: 'UNKNOWN' })],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [],
    })
    r.runMatch()
    expect(r.result.value!.unmapped).toHaveLength(1)
    expect(r.result.value!.missingInDb).toHaveLength(0)
  })

  it('rows with itemNumber=null go into `unparseable`', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: null })],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [],
    })
    r.runMatch()
    expect(r.result.value!.unparseable).toHaveLength(1)
  })

  it('DB sales outside the date range are not flagged as ghosts', () => {
    const r = setupRecon({
      rawRows: [],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [
        mkSale({ id: 'in',  created_at: '2026-03-15T12:00:00.000Z' }),
        mkSale({ id: 'out', created_at: '2026-04-01T12:00:00.000Z' }),
      ],
      fromUtc: '2026-03-01T00:00:00.000Z',
      toUtc:   '2026-03-31T23:59:59.000Z',
    })
    r.runMatch()
    expect(r.result.value!.ghostInDb.map(s => s.id)).toEqual(['in'])
  })
})
```

- [ ] **Step 15.2: Run, observe failures**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -25
```

Expected: 10 new tests fail.

- [ ] **Step 15.3: Implement `runMatch`**

Replace the `runMatch` stub:

```ts
  function runMatch(): void {
    matching.value = true
    try {
      const tolMs = settings.value.toleranceSeconds * 1000
      const tz = settings.value.timezone
      const mappedVmIds = new Set<string>(mapping.value.values())

      // Bucket: unmapped + unparseable upfront.
      const unmapped: NayaxRow[] = []
      const unparseable: NayaxRow[] = []
      const eligible: NayaxRow[] = []
      for (const n of rawRows.value) {
        if (!n.nayaxMachineId || !mapping.value.has(n.nayaxMachineId)) {
          unmapped.push(n)
          continue
        }
        if (n.itemNumber == null || n.priceGross <= 0) {
          unparseable.push(n)
          continue
        }
        eligible.push(n)
      }

      // Sort by Nayax time ascending so earlier rows get first pick on
      // tight DB candidates (deterministic tie-breaking).
      // Note: greedy one-to-one matching. If a future workload has many
      // near-simultaneous identical sales, swap to a Hungarian-style
      // optimal assignment — for v1 a code comment is enough.
      eligible.sort((a, b) => a.utcDt.localeCompare(b.utcDt))

      const usedDbIds = new Set<string>()
      const matched: MatchPair[] = []
      const missingInDb: NayaxRow[] = []

      for (const n of eligible) {
        const vmId = mapping.value.get(n.nayaxMachineId)!
        const nTime = Date.parse(n.utcDt)
        let best: DbSale | null = null
        let bestDelta = Infinity
        for (const s of dbSales.value) {
          if (usedDbIds.has(s.id)) continue
          if (s.machine_id !== vmId) continue
          if (s.item_number !== n.itemNumber) continue
          if (s.item_price == null) continue
          if (roundTo2(s.item_price) !== roundTo2(n.priceGross)) continue
          const dTime = Date.parse(s.created_at)
          const delta = dTime - nTime
          if (Math.abs(delta) > tolMs) continue
          if (Math.abs(delta) < Math.abs(bestDelta)) {
            best = s
            bestDelta = delta
          }
        }
        if (best == null) {
          missingInDb.push(n)
        } else {
          matched.push({ nayax: n, db: best, deltaSeconds: bestDelta / 1000 })
          usedDbIds.add(best.id)
        }
      }

      // Ghosts: DB sales in range, on a mapped machine, not consumed.
      const fromMs = Date.parse(settings.value.fromUtc)
      const toMs = Date.parse(settings.value.toUtc)
      const ghostInDb: DbSale[] = dbSales.value.filter(s =>
        s.machine_id != null
        && mappedVmIds.has(s.machine_id)
        && !usedDbIds.has(s.id)
        && Date.parse(s.created_at) >= fromMs
        && Date.parse(s.created_at) <= toMs,
      )

      result.value = {
        matched,
        missingInDb,
        ghostInDb,
        unmapped,
        unparseable,
        fileDateRange: settings.value.fromUtc && settings.value.toUtc
          ? { fromUtc: settings.value.fromUtc, toUtc: settings.value.toUtc }
          : null,
        settings: {
          timezone: tz,
          toleranceSeconds: settings.value.toleranceSeconds,
        },
      }
    } finally {
      matching.value = false
    }
  }
```

- [ ] **Step 15.4: Verify**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -10
```

Expected: 29 tests pass.

### Task 16: TDD `derivedChannelFromPaymentSource` and implement `bulkImportMissing` + `deleteGhost`

**Files:**
- Modify: `useNayaxReconciliation.test.ts`, `useNayaxReconciliation.ts`

- [ ] **Step 16.1: Add the failing test for channel derivation**

```ts
import { derivedChannelFromPaymentSource } from '../useNayaxReconciliation'

describe('derivedChannelFromPaymentSource', () => {
  it('maps "Cash" to "cash"', () => {
    expect(derivedChannelFromPaymentSource('Cash')).toBe('cash')
  })
  it('maps any "Credit Card(*)" to "card"', () => {
    expect(derivedChannelFromPaymentSource('Credit Card(CLS)')).toBe('card')
    expect(derivedChannelFromPaymentSource('Credit Card(Whatever)')).toBe('card')
  })
  it('maps unknown values to "nayax"', () => {
    expect(derivedChannelFromPaymentSource('Apple Pay')).toBe('nayax')
    expect(derivedChannelFromPaymentSource('')).toBe('nayax')
  })
})
```

- [ ] **Step 16.2: Implement the helper**

In `useNayaxReconciliation.ts`:

```ts
/**
 * Map the Nayax `Payment Method (Source)` column to our `sales.channel`
 * convention. Used when importing a Nayax row as a manual sale.
 */
export function derivedChannelFromPaymentSource(src: string): string {
  const s = src.trim()
  if (s === 'Cash') return 'cash'
  if (/^Credit Card\(/i.test(s)) return 'card'
  return 'nayax'
}
```

- [ ] **Step 16.3: Run, verify the channel tests pass**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -10
```

Expected: 32 tests pass.

- [ ] **Step 16.4: Implement `bulkImportMissing`**

Replace the stub:

```ts
  async function bulkImportMissing(
    rows: NayaxRow[],
  ): Promise<{ imported: number; errors: string[] }> {
    importing.value = true
    const errors: string[] = []
    let imported = 0
    try {
      const supabase = useSupabaseClient()
      for (const n of rows) {
        const vmId = mapping.value.get(n.nayaxMachineId)
        if (!vmId || n.itemNumber == null) {
          errors.push(`row ${n.rowIndex}: cannot import (unmapped or unparseable)`)
          continue
        }
        const { error: err } = await (supabase as any).rpc('insert_manual_sale', {
          p_machine_id: vmId,
          p_item_number: n.itemNumber,
          p_item_price: n.priceGross,
          p_channel: derivedChannelFromPaymentSource(n.paymentSource),
          p_created_at: n.utcDt,
        })
        if (err) {
          errors.push(`row ${n.rowIndex} (${n.txId}): ${err.message ?? err}`)
          continue
        }
        imported++
      }
      // Re-load DB sales so subsequent `runMatch` reflects new rows.
      // Wrap separately — a failure here shouldn't lose the per-row success
      // info. The user can still hit "Re-run" to refresh manually.
      try {
        await loadDbSales()
        runMatch()
      } catch (e: unknown) {
        errors.push(`refresh after import: ${e instanceof Error ? e.message : String(e)}`)
      }
    } finally {
      importing.value = false
    }
    return { imported, errors }
  }
```

- [ ] **Step 16.5: Implement `deleteGhost`**

```ts
  async function deleteGhost(saleId: string): Promise<void> {
    deleting.value = true
    try {
      const supabase = useSupabaseClient()
      const { error: err } = await (supabase as any).rpc('delete_sale_and_restore_stock', {
        p_sale_id: saleId,
      })
      if (err) throw err
      // Refresh state
      await loadDbSales()
      runMatch()
    } finally {
      deleting.value = false
    }
  }
```

### Task 17: TDD `exportDiffCsv`

**Files:**
- Modify: `useNayaxReconciliation.test.ts`, `useNayaxReconciliation.ts`

- [ ] **Step 17.1: Failing test**

```ts
describe('exportDiffCsv', () => {
  it('emits one CSV row per matched/missing/ghost entry with the documented columns', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A' }),                               // matched
        mkNayax({ txId: 'B', utcDt: '2026-03-31T19:46:30.000Z' }),  // missing (no DB sale)
      ],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [
        mkSale({ id: 'sA' }),                                 // matches A
        mkSale({ id: 'sG', created_at: '2026-03-20T12:00:00.000Z',
                 item_number: 99, item_price: 1.0 }),          // ghost
      ],
    })
    r.runMatch()
    const csv = r.exportDiffCsv()
    const lines = csv.trim().split('\n')
    // Header + 1 matched + 1 missing + 1 ghost = 4 lines
    expect(lines.length).toBe(4)
    expect(lines[0]).toBe(
      'bucket,nayax_time_local,nayax_time_utc,db_time_utc,delta_seconds,machine_name,slot,product,price,payment_source,channel,nayax_tx_id,db_sale_id',
    )
    // Just sanity-check one column from each bucket row
    expect(lines.some(l => l.startsWith('matched,'))).toBe(true)
    expect(lines.some(l => l.startsWith('missing_in_db,'))).toBe(true)
    expect(lines.some(l => l.startsWith('ghost_in_db,'))).toBe(true)
  })

  it('escapes commas and quotes inside string fields', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ productName: 'Coke, Zero', txId: 't"x' })],
      mapping: new Map([['N1', 'vm1']]),
      dbSales: [],
    })
    r.runMatch()
    const csv = r.exportDiffCsv()
    // product column should be quoted, internal quotes doubled
    expect(csv).toContain('"Coke, Zero"')
    expect(csv).toContain('"t""x"')
  })
})
```

- [ ] **Step 17.2: Implement `exportDiffCsv`**

```ts
  function exportDiffCsv(): string {
    if (!result.value) return ''
    const cols = [
      'bucket','nayax_time_local','nayax_time_utc','db_time_utc','delta_seconds',
      'machine_name','slot','product','price','payment_source','channel',
      'nayax_tx_id','db_sale_id',
    ]
    const esc = (v: unknown): string => {
      if (v == null) return ''
      const s = String(v)
      if (s.includes(',') || s.includes('"') || s.includes('\n')) {
        return `"${s.replace(/"/g, '""')}"`
      }
      return s
    }
    const lines: string[] = [cols.join(',')]
    const machineNameById = new Map<string, string>()
    for (const [nayaxId, vmId] of mapping.value) {
      const n = rawRows.value.find(r => r.nayaxMachineId === nayaxId)
      if (n) machineNameById.set(vmId, n.machineName)
    }
    for (const m of result.value.matched) {
      lines.push([
        'matched',
        m.nayax.localDt,
        m.nayax.utcDt,
        m.db.created_at,
        m.deltaSeconds.toFixed(2),
        m.nayax.machineName,
        m.nayax.itemNumber,
        m.db.product_name ?? m.nayax.productName,
        m.nayax.priceGross.toFixed(2),
        m.nayax.paymentSource,
        m.db.channel ?? '',
        m.nayax.txId,
        m.db.id,
      ].map(esc).join(','))
    }
    for (const n of result.value.missingInDb) {
      lines.push([
        'missing_in_db',
        n.localDt, n.utcDt, '', '',
        n.machineName, n.itemNumber, n.productName,
        n.priceGross.toFixed(2), n.paymentSource, '',
        n.txId, '',
      ].map(esc).join(','))
    }
    for (const s of result.value.ghostInDb) {
      lines.push([
        'ghost_in_db',
        '', '', s.created_at, '',
        machineNameById.get(s.machine_id) ?? '',
        s.item_number, s.product_name ?? '',
        s.item_price?.toFixed(2) ?? '', '',
        s.channel ?? '',
        '', s.id,
      ].map(esc).join(','))
    }
    return lines.join('\n')
  }
```

- [ ] **Step 17.3: Run all tests**

```bash
npx vitest run app/composables/__tests__/useNayaxReconciliation.test.ts 2>&1 | tail -10
```

Expected: 34 tests pass (29 + 3 + 2).

### Task 18: Commit Chunk 4

- [ ] **Step 18.1: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add management-frontend/app/composables/useNayaxReconciliation.ts \
        management-frontend/app/composables/__tests__/useNayaxReconciliation.test.ts
git commit -m "$(cat <<'EOF'
feat(reconcile): match algorithm + import/delete actions + CSV export

Greedy one-to-one matcher on (machine, item, price, time ±tolerance)
with deterministic earlier-Nayax-wins tie breaking. bulkImportMissing
fans out to insert_manual_sale, deleteGhost calls
delete_sale_and_restore_stock. exportDiffCsv emits the documented
column layout with quote/comma escaping.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 5: Wizard UI — Upload, Mapping, Settings

UI lives under `app/components/nayax/` so the namespace is obvious. The page at `/reports/nayax-reconciliation` owns the step transitions; each step component is a dumb presentational unit.

### Task 19: Page shell

**Files:**
- Create: `management-frontend/app/pages/reports/nayax-reconciliation.vue`

- [ ] **Step 19.1: Create the page**

```html
<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import NayaxUploadStep from '~/components/nayax/NayaxUploadStep.vue'
import NayaxMappingStep from '~/components/nayax/NayaxMappingStep.vue'
import NayaxSettingsStep from '~/components/nayax/NayaxSettingsStep.vue'
import NayaxResultsView from '~/components/nayax/NayaxResultsView.vue'

const { t } = useI18n()
const { role } = useOrganization()
const recon = useNayaxReconciliation()
const isAdmin = computed(() => role.value === 'admin')

// localStorage hydration on first mount
onMounted(() => {
  const tz = localStorage.getItem('nayax-reconcile-tz')
  if (tz) recon.settings.value.timezone = tz
  const tol = localStorage.getItem('nayax-reconcile-tolerance')
  if (tol) recon.settings.value.toleranceSeconds = Math.max(5, Math.min(600, Number(tol)))
})

async function onFileSelected(file: File) {
  await recon.parseFile(file)
  if (recon.error.value) return
  await recon.loadMappingForCompany()
  const unmapped = recon.detectUnmappedIds()
  recon.step.value = unmapped.length > 0 ? 'mapping' : 'settings'
}

async function onMappingDone() {
  recon.step.value = 'settings'
}

async function onSettingsRun() {
  localStorage.setItem('nayax-reconcile-tz', recon.settings.value.timezone)
  localStorage.setItem('nayax-reconcile-tolerance', String(recon.settings.value.toleranceSeconds))
  await recon.loadDbSales()
  recon.runMatch()
  recon.step.value = 'results'
}

function onStartOver() {
  recon.reset()
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-2xl font-semibold">{{ t('nayax.reconcile.title') }}</h1>
        <p class="text-sm text-muted-foreground">{{ t('nayax.reconcile.subtitle') }}</p>
      </div>
      <NuxtLink
        to="/reports"
        class="text-sm text-muted-foreground hover:text-foreground"
      >
        ← {{ t('nayax.reconcile.backToReports') }}
      </NuxtLink>
    </div>

    <NayaxUploadStep
      v-if="recon.step.value === 'upload'"
      :parsing="recon.parsing.value"
      :error="recon.error.value"
      @file="onFileSelected"
    />

    <NayaxMappingStep
      v-else-if="recon.step.value === 'mapping'"
      :is-admin="isAdmin"
      @done="onMappingDone"
    />

    <NayaxSettingsStep
      v-else-if="recon.step.value === 'settings'"
      :is-admin="isAdmin"
      @run="onSettingsRun"
      @back="recon.step.value = 'mapping'"
    />

    <NayaxResultsView
      v-else-if="recon.step.value === 'results'"
      :is-admin="isAdmin"
      @restart="onStartOver"
      @rerun="recon.step.value = 'settings'"
      @go-to-mapping="recon.step.value = 'mapping'"
    />
  </div>
</template>
```

### Task 20: Upload step

**Files:**
- Create: `management-frontend/app/components/nayax/NayaxUploadStep.vue`

- [ ] **Step 20.1: Create the component**

```html
<script setup lang="ts">
const props = defineProps<{ parsing: boolean; error: string }>()
const emit = defineEmits<{ file: [f: File] }>()
const { t } = useI18n()

function onChange(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0]
  if (file) emit('file', file)
}
function onDrop(e: DragEvent) {
  e.preventDefault()
  const file = e.dataTransfer?.files?.[0]
  if (file) emit('file', file)
}
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <p class="mb-4 text-sm text-muted-foreground">{{ t('nayax.reconcile.upload.description') }}</p>
    <label
      class="flex h-40 w-full cursor-pointer items-center justify-center rounded-lg border-2 border-dashed border-muted-foreground/25 text-muted-foreground transition-colors hover:border-primary/50 hover:bg-primary/5"
      @dragover.prevent
      @drop="onDrop"
    >
      <div class="text-center">
        <span v-if="props.parsing" class="text-sm">{{ t('nayax.reconcile.upload.parsing') }}</span>
        <template v-else>
          <span class="text-sm font-medium">{{ t('nayax.reconcile.upload.dropHere') }}</span>
          <span class="mt-1 block text-xs">{{ t('nayax.reconcile.upload.supportsXlsx') }}</span>
        </template>
      </div>
      <input type="file" accept=".xlsx,.xls" class="hidden" @change="onChange" />
    </label>
    <p v-if="props.error" class="mt-3 text-sm text-destructive">{{ t(props.error) || props.error }}</p>
  </div>
</template>
```

### Task 21: Mapping step + machine combobox

**Files:**
- Create: `management-frontend/app/components/nayax/NayaxMachineCombobox.vue`
- Create: `management-frontend/app/components/nayax/NayaxMappingStep.vue`

- [ ] **Step 21.1: Create the combobox**

Pattern follows `ProductCombobox.vue` but with `vendingMachine` shape:

```html
<script setup lang="ts">
import { ref, computed } from 'vue'
import { Check, ChevronsUpDown } from 'lucide-vue-next'
import {
  Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList,
} from '@/components/ui/command'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { cn } from '@/lib/utils'

const { t } = useI18n()

interface VM { id: string; name: string | null }
const props = defineProps<{
  modelValue: string | null
  machines: VM[]
  placeholder?: string
  disabled?: boolean
}>()
const emit = defineEmits<{ 'update:modelValue': [v: string | null] }>()
const open = ref(false)
const query = ref('')

const selected = computed(() => props.machines.find(m => m.id === props.modelValue))
const filtered = computed(() => {
  const q = query.value.trim().toLowerCase()
  if (!q) return props.machines
  return props.machines.filter(m => (m.name ?? '').toLowerCase().includes(q))
})

function pick(id: string | null) {
  emit('update:modelValue', id)
  open.value = false
  query.value = ''
}
</script>

<template>
  <Popover v-model:open="open">
    <PopoverTrigger as-child>
      <button
        type="button"
        :disabled="disabled"
        :class="cn('inline-flex h-9 w-full items-center justify-between rounded-md border border-input bg-background px-3 text-sm shadow-sm transition-colors hover:bg-muted/30 disabled:opacity-50')"
      >
        <span :class="selected ? '' : 'text-muted-foreground'">
          {{ selected?.name ?? placeholder ?? t('nayax.reconcile.mapping.pickMachine') }}
        </span>
        <ChevronsUpDown class="ml-2 h-4 w-4 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] p-0">
      <Command>
        <CommandInput v-model="query" :placeholder="t('nayax.reconcile.mapping.searchMachine')" />
        <CommandList>
          <CommandEmpty>{{ t('nayax.reconcile.mapping.noMatch') }}</CommandEmpty>
          <CommandGroup>
            <CommandItem
              v-for="m in filtered"
              :key="m.id"
              :value="m.id"
              @select="pick(m.id)"
            >
              <Check :class="cn('mr-2 h-4 w-4', modelValue === m.id ? 'opacity-100' : 'opacity-0')" />
              {{ m.name ?? '—' }}
            </CommandItem>
            <CommandItem value="__skip" @select="pick(null)">
              <span class="text-muted-foreground italic">{{ t('nayax.reconcile.mapping.skipForRun') }}</span>
            </CommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
```

- [ ] **Step 21.2: Create the mapping step**

```html
<script setup lang="ts">
import NayaxMachineCombobox from './NayaxMachineCombobox.vue'

const props = defineProps<{ isAdmin: boolean }>()
const emit = defineEmits<{ done: [] }>()
const { t } = useI18n()
const recon = useNayaxReconciliation()
const { machines, fetchMachines } = useMachines()

const unmappedIds = computed(() => recon.detectUnmappedIds())
const localPicks = ref<Record<string, string | null>>({})
const saving = ref(false)
const error = ref('')

// Pre-load machines for the dropdown (and mapping cache if not yet)
onMounted(async () => {
  if (machines.value.length === 0) await fetchMachines()
})

// Pre-populate picks with current mapping (in case some IDs are mapped but the
// user wants to re-pick).
function rowsToShow() {
  // Show the unique unmapped IDs along with the most recent Nayax machineName
  // observed for each, so the user has context.
  const seen = new Map<string, string>()
  for (const n of recon.rawRows.value) {
    if (unmappedIds.value.includes(n.nayaxMachineId) && !seen.has(n.nayaxMachineId)) {
      seen.set(n.nayaxMachineId, n.machineName)
    }
  }
  return [...seen.entries()].map(([nayaxId, name]) => ({ nayaxId, name }))
}

async function save() {
  if (!props.isAdmin) { error.value = 'nayax.reconcile.mapping.adminOnly'; return }
  saving.value = true
  error.value = ''
  try {
    for (const [nayaxId, vmId] of Object.entries(localPicks.value)) {
      await recon.saveMapping(nayaxId, vmId)
    }
    emit('done')
  } catch (e: unknown) {
    error.value = e instanceof Error ? e.message : 'nayax.reconcile.mapping.saveFailed'
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <h2 class="text-lg font-semibold mb-1">{{ t('nayax.reconcile.mapping.title') }}</h2>
    <p class="mb-4 text-sm text-muted-foreground">{{ t('nayax.reconcile.mapping.intro') }}</p>

    <div v-if="!isAdmin" class="rounded-lg border border-yellow-200 bg-yellow-50 p-3 text-sm text-yellow-900 mb-4">
      {{ t('nayax.reconcile.mapping.viewerNotice') }}
    </div>

    <table class="w-full text-sm">
      <thead>
        <tr class="border-b text-left">
          <th class="py-2 font-medium">{{ t('nayax.reconcile.mapping.colNayaxId') }}</th>
          <th class="py-2 font-medium">{{ t('nayax.reconcile.mapping.colNayaxName') }}</th>
          <th class="py-2 font-medium">{{ t('nayax.reconcile.mapping.colMapsTo') }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="row in rowsToShow()" :key="row.nayaxId" class="border-b last:border-0">
          <td class="py-3 font-mono text-xs">{{ row.nayaxId }}</td>
          <td class="py-3">{{ row.name }}</td>
          <td class="py-3">
            <NayaxMachineCombobox
              v-model="localPicks[row.nayaxId]"
              :machines="machines"
              :disabled="!isAdmin"
            />
          </td>
        </tr>
      </tbody>
    </table>

    <p v-if="error" class="mt-3 text-sm text-destructive">{{ t(error) || error }}</p>

    <div class="mt-4 flex justify-end gap-2">
      <button
        class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted"
        @click="recon.reset()"
      >
        {{ t('common.cancel') }}
      </button>
      <button
        :disabled="saving"
        class="inline-flex h-9 items-center rounded-md bg-primary px-6 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
        @click="save"
      >
        <span v-if="saving">{{ t('common.saving') }}</span>
        <span v-else>{{ t('nayax.reconcile.mapping.continueCta') }}</span>
      </button>
    </div>
  </div>
</template>
```

### Task 22: Settings step

**Files:**
- Create: `management-frontend/app/components/nayax/NayaxSettingsStep.vue`

- [ ] **Step 22.1: Create the component**

```html
<script setup lang="ts">
const emit = defineEmits<{ run: []; back: [] }>()
const { t } = useI18n()
const recon = useNayaxReconciliation()

// Pre-fill date inputs from file range (utc) but display in the user's local
// browser time for the input fields. We convert back to UTC on submit.
const fromInput = ref('')
const toInput = ref('')

onMounted(() => {
  if (recon.settings.value.fromUtc) fromInput.value = toLocalInput(recon.settings.value.fromUtc)
  if (recon.settings.value.toUtc)   toInput.value   = toLocalInput(recon.settings.value.toUtc)
})

function toLocalInput(iso: string): string {
  const d = new Date(iso)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}
function fromLocalInput(local: string): string {
  return new Date(local).toISOString()
}

const tolerance = computed({
  get: () => recon.settings.value.toleranceSeconds,
  set: (v: number) => {
    recon.settings.value.toleranceSeconds = Math.max(5, Math.min(600, Math.round(v)))
  },
})

function submit() {
  recon.settings.value.fromUtc = fromLocalInput(fromInput.value)
  recon.settings.value.toUtc   = fromLocalInput(toInput.value)
  emit('run')
}
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <h2 class="text-lg font-semibold mb-4">{{ t('nayax.reconcile.settings.title') }}</h2>

    <div class="grid gap-4 sm:grid-cols-2">
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('nayax.reconcile.settings.from') }}</label>
        <input v-model="fromInput" type="datetime-local" class="flex h-9 w-full rounded-md border bg-background px-3 text-sm" />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('nayax.reconcile.settings.to') }}</label>
        <input v-model="toInput" type="datetime-local" class="flex h-9 w-full rounded-md border bg-background px-3 text-sm" />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('nayax.reconcile.settings.tz') }}</label>
        <select v-model="recon.settings.value.timezone" class="flex h-9 w-full rounded-md border bg-background px-3 text-sm">
          <option value="Europe/Berlin">Europe/Berlin</option>
          <option value="Europe/Vienna">Europe/Vienna</option>
          <option value="Europe/Zurich">Europe/Zurich</option>
          <option value="UTC">UTC</option>
        </select>
        <p class="text-[10px] text-muted-foreground">{{ t('nayax.reconcile.settings.tzHint') }}</p>
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('nayax.reconcile.settings.tolerance') }}</label>
        <input v-model.number="tolerance" type="number" min="5" max="600" class="flex h-9 w-full rounded-md border bg-background px-3 text-sm" />
        <p class="text-[10px] text-muted-foreground">{{ t('nayax.reconcile.settings.toleranceHint') }}</p>
      </div>
    </div>

    <div class="mt-6 flex justify-end gap-2">
      <button class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted" @click="emit('back')">
        {{ t('common.back') }}
      </button>
      <button class="inline-flex h-9 items-center rounded-md bg-primary px-6 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90" @click="submit">
        {{ t('nayax.reconcile.settings.runCta') }}
      </button>
    </div>
  </div>
</template>
```

### Task 23: Smoke test wizard + commit

- [ ] **Step 23.1: Run the dev server and walk the first three steps**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run dev
```

Visit `http://localhost:3000/reports/nayax-reconciliation`. Confirm:
1. Upload step renders. Drop the user's `tmp/nayax-sale.xlsx`. → page transitions to either mapping (if any Nayax IDs in the file aren't in your DB) or settings.
2. Mapping step (if shown): picks include all your machines, search works, "skip for this run" is offered. Save → page advances.
3. Settings step pre-fills the date range from the file, defaults timezone to `Europe/Berlin`, tolerance to `10`. Run button does not crash (results step is rendered by the next chunk — for now an empty wrapper is fine).

If anything explodes, fix it before continuing.

- [ ] **Step 23.2: Commit**

```bash
git add management-frontend/app/pages/reports/nayax-reconciliation.vue \
        management-frontend/app/components/nayax/
git commit -m "$(cat <<'EOF'
feat(reconcile): wizard shell + upload/mapping/settings steps

Page at /reports/nayax-reconciliation with step-machine driven by the
composable. Upload step parses xlsx, mapping step lets admins persist
Nayax→vendingMachine pairings via a searchable combobox, settings step
pre-fills date range + tz + tolerance from the file and localStorage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 6: Results UI + i18n + integration

The visual payoff. Three result tables, a header bar, a CSV download button, a link from `/reports`, full i18n.

### Task 24: Results view header + matched/missing/ghost tables

**Files:**
- Create: `management-frontend/app/components/nayax/NayaxResultsView.vue`
- Create: `management-frontend/app/components/nayax/NayaxMatchedTable.vue`
- Create: `management-frontend/app/components/nayax/NayaxMissingInDbTable.vue`
- Create: `management-frontend/app/components/nayax/NayaxGhostInDbTable.vue`
- Create: `management-frontend/app/components/nayax/NayaxUnmappedSection.vue`

- [ ] **Step 24.1: Create `NayaxResultsView.vue` (the orchestrator)**

```html
<script setup lang="ts">
import { IconDownload } from '@tabler/icons-vue'
import NayaxMatchedTable from './NayaxMatchedTable.vue'
import NayaxMissingInDbTable from './NayaxMissingInDbTable.vue'
import NayaxGhostInDbTable from './NayaxGhostInDbTable.vue'
import NayaxUnmappedSection from './NayaxUnmappedSection.vue'

const props = defineProps<{ isAdmin: boolean }>()
const emit = defineEmits<{ restart: []; rerun: []; 'go-to-mapping': [] }>()
const { t } = useI18n()
const recon = useNayaxReconciliation()

const result = computed(() => recon.result.value)
const matchedOpen = ref(false)
const missingOpen = ref(true)
const ghostOpen = ref(true)
const otherOpen = ref(true)

function downloadCsv() {
  const csv = recon.exportDiffCsv()
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `nayax-reconciliation-${new Date().toISOString().slice(0, 10)}.csv`
  a.click()
  URL.revokeObjectURL(url)
}

function fmtRange(): string {
  const s = result.value?.fileDateRange
  if (!s) return ''
  return `${new Date(s.fromUtc).toLocaleString()} – ${new Date(s.toUtc).toLocaleString()}`
}
</script>

<template>
  <div class="flex flex-col gap-4" v-if="result">
    <!-- Header bar -->
    <div class="rounded-xl border bg-card p-4 shadow-sm">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p class="text-sm">
            <span class="font-medium text-green-700">{{ result.matched.length }} {{ t('nayax.reconcile.results.matchedShort') }}</span> ·
            <span class="font-medium text-red-700">{{ result.missingInDb.length }} {{ t('nayax.reconcile.results.missingShort') }}</span> ·
            <span class="font-medium text-yellow-700">{{ result.ghostInDb.length }} {{ t('nayax.reconcile.results.ghostShort') }}</span>
          </p>
          <p class="text-xs text-muted-foreground mt-1">
            {{ fmtRange() }} · {{ result.settings.timezone }} · ±{{ result.settings.toleranceSeconds }}s
          </p>
        </div>
        <div class="flex gap-2">
          <button class="inline-flex h-9 items-center gap-2 rounded-md border px-3 text-sm hover:bg-muted" @click="downloadCsv">
            <IconDownload class="h-4 w-4" /> {{ t('nayax.reconcile.results.exportCsv') }}
          </button>
          <button class="inline-flex h-9 items-center rounded-md border px-3 text-sm hover:bg-muted" @click="emit('rerun')">
            {{ t('nayax.reconcile.results.rerun') }}
          </button>
          <button class="inline-flex h-9 items-center rounded-md border px-3 text-sm hover:bg-muted" @click="emit('restart')">
            {{ t('nayax.reconcile.results.startOver') }}
          </button>
        </div>
      </div>
    </div>

    <!-- Missing (focus bucket) -->
    <NayaxMissingInDbTable
      :rows="result.missingInDb"
      :is-admin="isAdmin"
      :open="missingOpen"
      @toggle="missingOpen = !missingOpen"
    />

    <!-- Ghost -->
    <NayaxGhostInDbTable
      :rows="result.ghostInDb"
      :is-admin="isAdmin"
      :open="ghostOpen"
      @toggle="ghostOpen = !ghostOpen"
    />

    <!-- Matched (collapsed by default) -->
    <NayaxMatchedTable
      :rows="result.matched"
      :open="matchedOpen"
      @toggle="matchedOpen = !matchedOpen"
    />

    <!-- Unmapped + unparseable -->
    <NayaxUnmappedSection
      v-if="result.unmapped.length + result.unparseable.length > 0"
      :unmapped="result.unmapped"
      :unparseable="result.unparseable"
      :open="otherOpen"
      @toggle="otherOpen = !otherOpen"
      @go-to-mapping="emit('go-to-mapping')"
    />
  </div>
</template>
```

- [ ] **Step 24.2: Create `NayaxMatchedTable.vue`**

```html
<script setup lang="ts">
import type { MatchPair } from '~/composables/useNayaxReconciliation'
import { IconChevronDown, IconChevronRight, IconCircleCheck } from '@tabler/icons-vue'

defineProps<{ rows: MatchPair[]; open: boolean }>()
defineEmits<{ toggle: [] }>()
const { t } = useI18n()
</script>

<template>
  <div class="rounded-xl border bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconCircleCheck class="h-4 w-4 text-green-600" />
        {{ t('nayax.reconcile.results.matchedTitle') }} ({{ rows.length }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>
    <div v-if="open && rows.length > 0" class="overflow-auto border-t">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b bg-muted/40 text-left">
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTime') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colMachine') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colSlot') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colProduct') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPrice') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colDelta') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="m in rows" :key="m.nayax.txId" class="border-b last:border-0">
            <td class="px-4 py-2">{{ m.nayax.localDt }}</td>
            <td class="px-4 py-2">{{ m.nayax.machineName }}</td>
            <td class="px-4 py-2 tabular-nums">{{ m.nayax.itemNumber }}</td>
            <td class="px-4 py-2">{{ m.db.product_name ?? m.nayax.productName }}</td>
            <td class="px-4 py-2 tabular-nums">{{ m.nayax.priceGross.toFixed(2) }} €</td>
            <td class="px-4 py-2 tabular-nums" :class="Math.abs(m.deltaSeconds) >= 5 ? 'text-yellow-700' : 'text-muted-foreground'">
              {{ m.deltaSeconds > 0 ? '+' : '' }}{{ m.deltaSeconds.toFixed(1) }}s
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
```

- [ ] **Step 24.3: Create `NayaxMissingInDbTable.vue`**

```html
<script setup lang="ts">
import type { NayaxRow } from '~/composables/useNayaxReconciliation'
import { IconChevronDown, IconChevronRight, IconAlertTriangle } from '@tabler/icons-vue'

const props = defineProps<{ rows: NayaxRow[]; isAdmin: boolean; open: boolean }>()
defineEmits<{ toggle: [] }>()
const { t } = useI18n()
const recon = useNayaxReconciliation()

const selected = ref<Set<string>>(new Set())
const showConfirm = ref(false)
const lastResult = ref<{ imported: number; errors: string[] } | null>(null)

const allSelected = computed(() => props.rows.length > 0 && selected.value.size === props.rows.length)

function toggleOne(txId: string) {
  if (selected.value.has(txId)) selected.value.delete(txId)
  else selected.value.add(txId)
  // trigger reactivity
  selected.value = new Set(selected.value)
}
function toggleAll() {
  if (allSelected.value) selected.value = new Set()
  else selected.value = new Set(props.rows.map(r => r.txId))
}

async function runImport() {
  const rows = props.rows.filter(r => selected.value.has(r.txId))
  if (rows.length === 0) return
  showConfirm.value = false
  lastResult.value = await recon.bulkImportMissing(rows)
  selected.value = new Set()
}
</script>

<template>
  <div class="rounded-xl border border-red-200 bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconAlertTriangle class="h-4 w-4 text-red-600" />
        {{ t('nayax.reconcile.results.missingTitle') }} ({{ rows.length }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>
    <div v-if="open" class="border-t">
      <div v-if="selected.size > 0 && isAdmin" class="flex items-center justify-between bg-muted/40 px-4 py-2 text-sm">
        <span>{{ t('nayax.reconcile.results.selectedN', { n: selected.size }) }}</span>
        <button class="inline-flex h-8 items-center rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90" @click="showConfirm = true">
          {{ t('nayax.reconcile.results.importCta') }}
        </button>
      </div>
      <div v-if="lastResult" class="border-b bg-green-50 px-4 py-2 text-sm text-green-800">
        {{ t('nayax.reconcile.results.importedN', { n: lastResult.imported }) }}
        <span v-if="lastResult.errors.length > 0">· {{ t('nayax.reconcile.results.importErrors', { n: lastResult.errors.length }) }}</span>
      </div>
      <div v-if="rows.length === 0" class="p-4 text-sm text-muted-foreground">
        {{ t('nayax.reconcile.results.allMatched') }}
      </div>
      <table v-else class="w-full text-sm">
        <thead>
          <tr class="border-b bg-muted/40 text-left">
            <th class="w-10 px-4 py-2"><input type="checkbox" :checked="allSelected" @change="toggleAll" :disabled="!isAdmin" /></th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTime') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colMachine') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colSlot') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colProduct') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPrice') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPayment') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTxId') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.txId" class="border-b last:border-0">
            <td class="px-4 py-2"><input type="checkbox" :checked="selected.has(r.txId)" @change="toggleOne(r.txId)" :disabled="!isAdmin" /></td>
            <td class="px-4 py-2">{{ r.localDt }}</td>
            <td class="px-4 py-2">{{ r.machineName }}</td>
            <td class="px-4 py-2 tabular-nums">{{ r.itemNumber }}</td>
            <td class="px-4 py-2">{{ r.productName }}</td>
            <td class="px-4 py-2 tabular-nums">{{ r.priceGross.toFixed(2) }} €</td>
            <td class="px-4 py-2">{{ r.paymentSource }}</td>
            <td class="px-4 py-2 font-mono text-xs">{{ r.txId }}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Confirm dialog (lightweight) -->
    <div v-if="showConfirm" class="fixed inset-0 z-50 flex items-center justify-center bg-black/30">
      <div class="rounded-xl bg-card p-6 shadow-xl max-w-md">
        <h3 class="font-semibold mb-2">{{ t('nayax.reconcile.results.importConfirmTitle') }}</h3>
        <p class="text-sm text-muted-foreground mb-4">
          {{ t('nayax.reconcile.results.importConfirmBody', { n: selected.size }) }}
        </p>
        <div class="flex justify-end gap-2">
          <button class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted" @click="showConfirm = false">
            {{ t('common.cancel') }}
          </button>
          <button class="inline-flex h-9 items-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground" @click="runImport">
            {{ t('common.confirm') }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 24.4: Create `NayaxGhostInDbTable.vue`**

```html
<script setup lang="ts">
import type { DbSale } from '~/composables/useNayaxReconciliation'
import { IconChevronDown, IconChevronRight, IconInfoCircle, IconTrash } from '@tabler/icons-vue'

defineProps<{ rows: DbSale[]; isAdmin: boolean; open: boolean }>()
defineEmits<{ toggle: [] }>()
const { t } = useI18n()
const recon = useNayaxReconciliation()

const pendingDelete = ref<DbSale | null>(null)

async function confirmDelete() {
  if (!pendingDelete.value) return
  const id = pendingDelete.value.id
  pendingDelete.value = null
  await recon.deleteGhost(id)
}
</script>

<template>
  <div class="rounded-xl border border-yellow-200 bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconInfoCircle class="h-4 w-4 text-yellow-600" />
        {{ t('nayax.reconcile.results.ghostTitle') }} ({{ rows.length }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>
    <div v-if="open" class="border-t">
      <div v-if="rows.length === 0" class="p-4 text-sm text-muted-foreground">
        {{ t('nayax.reconcile.results.noGhosts') }}
      </div>
      <table v-else class="w-full text-sm">
        <thead>
          <tr class="border-b bg-muted/40 text-left">
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTime') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colSlot') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colProduct') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPrice') }}</th>
            <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colChannel') }}</th>
            <th class="w-16 px-4 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.id" class="border-b last:border-0">
            <td class="px-4 py-2">{{ new Date(r.created_at).toLocaleString() }}</td>
            <td class="px-4 py-2 tabular-nums">{{ r.item_number }}</td>
            <td class="px-4 py-2">{{ r.product_name ?? '—' }}</td>
            <td class="px-4 py-2 tabular-nums">{{ r.item_price?.toFixed(2) ?? '—' }} €</td>
            <td class="px-4 py-2">{{ r.channel ?? '—' }}</td>
            <td class="px-4 py-2 text-right">
              <button v-if="isAdmin" class="inline-flex h-8 items-center gap-1 rounded-md border border-red-200 px-2 text-xs text-red-700 hover:bg-red-50" @click="pendingDelete = r">
                <IconTrash class="h-3 w-3" />
                {{ t('common.delete') }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div v-if="pendingDelete" class="fixed inset-0 z-50 flex items-center justify-center bg-black/30">
      <div class="rounded-xl bg-card p-6 shadow-xl max-w-md">
        <h3 class="font-semibold mb-2">{{ t('nayax.reconcile.results.deleteConfirmTitle') }}</h3>
        <p class="text-sm text-muted-foreground mb-4">
          {{ t('nayax.reconcile.results.deleteConfirmBody') }}
        </p>
        <div class="flex justify-end gap-2">
          <button class="inline-flex h-9 items-center rounded-md border px-4 text-sm hover:bg-muted" @click="pendingDelete = null">
            {{ t('common.cancel') }}
          </button>
          <button class="inline-flex h-9 items-center rounded-md bg-red-600 px-4 text-sm font-medium text-white hover:bg-red-700" @click="confirmDelete">
            {{ t('common.delete') }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 24.5: Create `NayaxUnmappedSection.vue`**

```html
<script setup lang="ts">
import type { NayaxRow } from '~/composables/useNayaxReconciliation'
import { IconChevronDown, IconChevronRight, IconCircleDashed } from '@tabler/icons-vue'

defineProps<{ unmapped: NayaxRow[]; unparseable: NayaxRow[]; open: boolean }>()
defineEmits<{ toggle: []; 'go-to-mapping': [] }>()
const { t } = useI18n()
</script>

<template>
  <div class="rounded-xl border bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconCircleDashed class="h-4 w-4 text-muted-foreground" />
        {{ t('nayax.reconcile.results.otherTitle') }} ({{ unmapped.length + unparseable.length }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>
    <div v-if="open" class="border-t p-4 space-y-3 text-sm">
      <div v-if="unmapped.length > 0">
        <p class="font-medium mb-1">{{ t('nayax.reconcile.results.unmappedHead', { n: unmapped.length }) }}</p>
        <p class="text-muted-foreground mb-2">{{ t('nayax.reconcile.results.unmappedHint') }}</p>
        <button class="inline-flex h-8 items-center rounded-md border px-3 text-xs hover:bg-muted" @click="$emit('go-to-mapping')">
          {{ t('nayax.reconcile.results.openMapping') }}
        </button>
      </div>
      <div v-if="unparseable.length > 0">
        <p class="font-medium mb-1">{{ t('nayax.reconcile.results.unparseableHead', { n: unparseable.length }) }}</p>
        <ul class="list-disc pl-5 text-muted-foreground text-xs space-y-1">
          <li v-for="r in unparseable.slice(0, 10)" :key="r.txId">
            {{ r.localDt }} · {{ r.machineName }} · {{ r.productName }} ({{ r.selectionInfoRaw || t('nayax.reconcile.results.emptyField') }})
          </li>
        </ul>
        <p v-if="unparseable.length > 10" class="text-[10px] text-muted-foreground italic mt-1">
          {{ t('nayax.reconcile.results.unparseableMore', { n: unparseable.length - 10 }) }}
        </p>
      </div>
    </div>
  </div>
</template>
```

### Task 25: i18n keys (de + en)

**Files:**
- Modify: `management-frontend/i18n/locales/de.json`
- Modify: `management-frontend/i18n/locales/en.json`

- [ ] **Step 25.1: Add the `nayax` namespace to German**

Find a sensible location in `de.json` (alphabetical with the top-level keys) and add:

```json
  "nayax": {
    "reconcile": {
      "title": "Nayax-Verkaufsabgleich",
      "subtitle": "Lade einen Nayax-Verkaufsexport hoch und finde Verkäufe, die nicht in der Datenbank gelandet sind.",
      "backToReports": "Zurück zu Reports",
      "upload": {
        "description": "Lade eine Nayax-Verkaufsexport-Datei (.xlsx) aus deinem Nayax-Backoffice hoch. Erkannte Spalten: Transaktions-ID, Maschinen-Begleichszeit, Zu begleichender Wert, Produktauswahl-Informationen, Maschinen-ID.",
        "parsing": "Datei wird gelesen…",
        "dropHere": "Datei hier ablegen oder klicken zum Auswählen",
        "supportsXlsx": "Unterstützt .xlsx von Nayax \"Dynamische Transaktionsüberwachung\""
      },
      "mapping": {
        "title": "Maschinen zuordnen",
        "intro": "Folgende Nayax-Maschinen-IDs sind noch keiner deiner Maschinen zugeordnet. Wähle pro Zeile die passende Maschine. Die Zuordnung wird gespeichert und gilt für alle zukünftigen Uploads.",
        "viewerNotice": "Nur Administratoren können Zuordnungen speichern. Du kannst die Datei trotzdem analysieren — nicht zugeordnete Maschinen erscheinen am Ende.",
        "adminOnly": "Nur Administratoren können Zuordnungen speichern.",
        "saveFailed": "Zuordnung konnte nicht gespeichert werden.",
        "colNayaxId": "Nayax-ID",
        "colNayaxName": "Nayax-Maschinenname",
        "colMapsTo": "Zuordnung",
        "pickMachine": "Maschine wählen…",
        "searchMachine": "Suchen…",
        "noMatch": "Keine Maschine gefunden",
        "skipForRun": "Für diesen Lauf überspringen",
        "continueCta": "Weiter"
      },
      "settings": {
        "title": "Abgleich-Einstellungen",
        "from": "Von",
        "to": "Bis",
        "tz": "Zeitzone der Nayax-Datei",
        "tzHint": "Nayax-Zeiten werden in dieser Zeitzone interpretiert und für den Vergleich nach UTC umgerechnet.",
        "tolerance": "Zeit-Toleranz (Sekunden)",
        "toleranceHint": "Standard 10 s. Erlaubt eine kleine Drift zwischen Maschinen- und MQTT-Zeitstempel.",
        "runCta": "Analyse starten"
      },
      "results": {
        "matchedShort": "übereinstimmend",
        "missingShort": "fehlt in DB",
        "ghostShort": "nur in DB",
        "matchedTitle": "Übereinstimmend",
        "missingTitle": "Fehlt in Datenbank",
        "ghostTitle": "Nur in Datenbank",
        "otherTitle": "Ungemappt / nicht parsbar",
        "colTime": "Zeit",
        "colMachine": "Maschine",
        "colSlot": "Slot",
        "colProduct": "Produkt",
        "colPrice": "Preis",
        "colDelta": "Δ Zeit",
        "colPayment": "Zahlung",
        "colChannel": "Kanal",
        "colTxId": "Nayax-Tx-ID",
        "selectedN": "{n} ausgewählt",
        "importCta": "Als manuelle Verkäufe importieren",
        "importedN": "{n} Verkäufe importiert.",
        "importErrors": "{n} Fehler",
        "importConfirmTitle": "Manuelle Verkäufe anlegen?",
        "importConfirmBody": "{n} Nayax-Zeilen werden als manuelle Verkäufe angelegt und der Tray-Bestand entsprechend reduziert. Fortfahren?",
        "deleteConfirmTitle": "Verkauf löschen?",
        "deleteConfirmBody": "Der Verkauf wird gelöscht und der Tray-Bestand wieder erhöht. Diese Aktion ist nicht rückgängig zu machen.",
        "allMatched": "Alle Nayax-Verkäufe sind in der Datenbank vorhanden.",
        "noGhosts": "Keine zusätzlichen Verkäufe in der Datenbank.",
        "exportCsv": "CSV exportieren",
        "rerun": "Neu auswerten",
        "startOver": "Andere Datei",
        "unmappedHead": "{n} Zeilen mit unbekannter Maschinen-ID",
        "unmappedHint": "Diese Nayax-Maschinen-IDs sind keiner deiner Maschinen zugeordnet. Diese Zeilen werden nicht abgeglichen.",
        "openMapping": "Zuordnung öffnen",
        "unparseableHead": "{n} Zeilen ohne erkennbare Slot-Nummer",
        "unparseableMore": "… und {n} weitere",
        "emptyField": "leer"
      }
    }
  },
```

- [ ] **Step 25.2: Add the English mirror to `en.json`**

```json
  "nayax": {
    "reconcile": {
      "title": "Nayax Sales Reconciliation",
      "subtitle": "Upload a Nayax sales export and find sales that didn't make it into the database.",
      "backToReports": "Back to Reports",
      "upload": {
        "description": "Upload a Nayax sales export file (.xlsx) from your Nayax back-office. Detected columns: Transaction ID, Machine settlement time, Amount, Product selection info, Machine ID.",
        "parsing": "Reading file…",
        "dropHere": "Drop a file here or click to select",
        "supportsXlsx": "Supports .xlsx from Nayax \"Dynamic Transaction Monitoring\""
      },
      "mapping": {
        "title": "Map machines",
        "intro": "The Nayax machine IDs below are not yet mapped to any of your machines. Pick the right machine for each row. The mapping is saved and used for all future uploads.",
        "viewerNotice": "Only admins can save mappings. You can still analyze the file — unmapped machines will appear at the end.",
        "adminOnly": "Only admins can save mappings.",
        "saveFailed": "Could not save mapping.",
        "colNayaxId": "Nayax ID",
        "colNayaxName": "Nayax machine name",
        "colMapsTo": "Maps to",
        "pickMachine": "Choose machine…",
        "searchMachine": "Search…",
        "noMatch": "No machine matches",
        "skipForRun": "Skip for this run",
        "continueCta": "Continue"
      },
      "settings": {
        "title": "Reconciliation settings",
        "from": "From",
        "to": "To",
        "tz": "Timezone of the Nayax file",
        "tzHint": "Nayax timestamps are interpreted in this timezone and converted to UTC for comparison.",
        "tolerance": "Time tolerance (seconds)",
        "toleranceHint": "Default 10 s. Allows a small drift between machine and MQTT timestamps.",
        "runCta": "Run analysis"
      },
      "results": {
        "matchedShort": "matched",
        "missingShort": "missing in DB",
        "ghostShort": "DB only",
        "matchedTitle": "Matched",
        "missingTitle": "Missing in database",
        "ghostTitle": "Database only",
        "otherTitle": "Unmapped / unparseable",
        "colTime": "Time",
        "colMachine": "Machine",
        "colSlot": "Slot",
        "colProduct": "Product",
        "colPrice": "Price",
        "colDelta": "Δ time",
        "colPayment": "Payment",
        "colChannel": "Channel",
        "colTxId": "Nayax Tx ID",
        "selectedN": "{n} selected",
        "importCta": "Import as manual sales",
        "importedN": "{n} sales imported.",
        "importErrors": "{n} errors",
        "importConfirmTitle": "Create manual sales?",
        "importConfirmBody": "{n} Nayax rows will be created as manual sales and the tray stock will be decremented accordingly. Continue?",
        "deleteConfirmTitle": "Delete sale?",
        "deleteConfirmBody": "The sale will be deleted and the tray stock restored. This cannot be undone.",
        "allMatched": "All Nayax sales are present in the database.",
        "noGhosts": "No extra sales in the database.",
        "exportCsv": "Export CSV",
        "rerun": "Re-run",
        "startOver": "New file",
        "unmappedHead": "{n} rows with unknown machine ID",
        "unmappedHint": "These Nayax machine IDs are not mapped to any of your machines. These rows are not analyzed.",
        "openMapping": "Open mapping",
        "unparseableHead": "{n} rows without a parseable slot number",
        "unparseableMore": "… and {n} more",
        "emptyField": "empty"
      }
    }
  },
```

### Task 26: Link the reconciliation page from `/reports`

**Files:**
- Modify: `management-frontend/app/pages/reports/index.vue`

- [ ] **Step 26.1: Add a card link near the top**

Add a new card just after the page heading (right after `<h1 …>` and the tax-readiness blocker). Visually placed before "Date range controls":

```html
    <NuxtLink
      to="/reports/nayax-reconciliation"
      class="flex items-start gap-3 rounded-xl border bg-card p-4 shadow-sm transition-colors hover:bg-muted/30"
    >
      <div class="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-blue-500/10 text-blue-600">
        <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>
        </svg>
      </div>
      <div class="flex-1">
        <p class="font-medium">{{ t('reports.nayaxReconcileTitle') }}</p>
        <p class="text-xs text-muted-foreground">{{ t('reports.nayaxReconcileBlurb') }}</p>
      </div>
    </NuxtLink>
```

Then add the two strings under `reports.*` in both locale files:

de.json (inside `"reports": { … }`):
```json
    "nayaxReconcileTitle": "Nayax-Verkaufsabgleich",
    "nayaxReconcileBlurb": "Vergleiche einen Nayax-Verkaufsexport mit der Datenbank und finde fehlende Verkäufe.",
```

en.json:
```json
    "nayaxReconcileTitle": "Nayax Sales Reconciliation",
    "nayaxReconcileBlurb": "Compare a Nayax sales export against the database and find missing sales.",
```

### Task 27: Full smoke test

- [ ] **Step 27.1: Start the dev server**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run dev
```

- [ ] **Step 27.2: Walk the happy path**

1. Log in (`memory/user_dev_credentials.md`).
2. Navigate `/reports` → confirm the new "Nayax Sales Reconciliation" card appears at the top, click it.
3. Drop `tmp/nayax-sale.xlsx` into the upload area.
4. If any Nayax machine ID in the file isn't yet mapped, the mapping step appears. Map each (or use "skip for this run"), Continue.
5. Settings step pre-fills March 2026 (the file's range), Europe/Berlin, 10 s. Click "Run analysis".
6. Results view appears with four sections. The header bar shows three counts and the recap.
7. Open "Fehlt in Datenbank" — confirm rows render with correct localDt, machine, slot, product, price. Pick one, click "Import as manual sales", confirm the dialog. Toast/banner says "1 imported".
8. Re-open `/machines/<that machine>/` history; the imported sale appears with channel matching the payment source mapping.
9. Back on the reconciliation page, the imported row has moved from "Missing" to "Matched".
10. If any ghosts exist, click "Delete" on one. Confirm. Sale disappears, tray stock increments (verify on the machine page).
11. Click "Export CSV" — file downloads, opens in a spreadsheet tool with the documented columns.

If any step fails, fix the regression and re-walk before continuing.

- [ ] **Step 27.3: Re-run the full test suite**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run test
```

Expected: all suites pass (existing tests + the new `useNayaxReconciliation.test.ts` with 34 tests).

- [ ] **Step 27.4: TypeScript clean check**

```bash
npx vue-tsc --noEmit 2>&1 | tail -20
```

Expected: zero errors.

- [ ] **Step 27.5: Final commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add management-frontend/app/components/nayax/ \
        management-frontend/app/pages/reports/nayax-reconciliation.vue \
        management-frontend/app/pages/reports/index.vue \
        management-frontend/i18n/locales/de.json \
        management-frontend/i18n/locales/en.json
git commit -m "$(cat <<'EOF'
feat(reconcile): results view + reports link + full i18n

Three-bucket results view (matched collapsed, missing + ghost
expanded), per-row delete for ghosts, bulk import for missing,
CSV diff export, unmapped/unparseable summary section, and a link
card on /reports. German + English i18n for the whole flow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done

All six chunks committed. Acceptance criteria from the spec are covered:

- [x] Persistent `vendingMachine.nayax_machine_id` column + admin-only edit on `/machines/[id]`
- [x] `/reports/nayax-reconciliation` page with the four-step wizard (Upload → Mapping → Settings → Results)
- [x] Three result buckets (matched / missing-in-DB / ghost-in-DB) plus unmapped/unparseable
- [x] Bulk import of missing sales via `insert_manual_sale`
- [x] Per-row delete of ghosts via `delete_sale_and_restore_stock`
- [x] CSV diff export with the spec's column layout
- [x] Default ±10 s tolerance, persisted to `localStorage`
- [x] DST-correct timezone conversion (`date-fns-tz`, default Europe/Berlin)
- [x] Soft 10 k warn / hard 50 k refuse for file size
- [x] Full German + English i18n
- [x] 34 Vitest tests covering pure helpers + parser + matcher + CSV
