# Nayax Reconciliation — Merged Chronological Differences View

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the "Fehlt in Datenbank" and "Nur in Datenbank" sections of `/reports/nayax-reconciliation` into one chronologically-sorted "Abweichungen" table, with per-row bucket badges and a unified `formatDateTime` date format across all result tables.

**Architecture:** Pure frontend UI refactor. Delete two existing components (`NayaxMissingInDbTable.vue`, `NayaxGhostInDbTable.vue`), create one replacement (`NayaxDifferencesTable.vue`), make a one-line cosmetic change to `NayaxMatchedTable.vue`, and update the orchestrator `NayaxResultsView.vue` to render the new shape. Composable API, matcher logic, CSV export, and DB are all unchanged.

**Tech Stack:** Vue 3 composition API, TypeScript, shadcn-nuxt (`AppModal`), TailwindCSS 4, `@tabler/icons-vue`, `@nuxtjs/i18n` (de/en), Vitest (no new tests — composable behavior unchanged).

**Spec:** [docs/superpowers/specs/2026-05-22-nayax-reconciliation-merged-differences-design.md](../specs/2026-05-22-nayax-reconciliation-merged-differences-design.md)

**Verification model:** No new unit tests — the matcher is untouched. After the refactor: `npx vue-tsc --noEmit` clean, `npm run test` still 141 passing, manual smoke test via `npm run dev` (or `curl -sI` if the dev env's edge-function DNS is broken).

---

## Pre-flight

- [ ] **Step 0.1: Confirm baseline is healthy**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run test 2>&1 | tail -5
```

Expected: `Test Files 13 passed (13)` + `Tests 141 passed (141)`. If anything fails on `main` before your changes, stop and tell the user — don't start work on a broken baseline.

```bash
npx vue-tsc --noEmit 2>&1 | grep nayax | head -5
```

Expected: no output (no pre-existing nayax-related type errors).

- [ ] **Step 0.2: Confirm current state of the files you're about to touch**

```bash
ls -la /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/components/nayax/
```

Expected to see: `NayaxGhostInDbTable.vue`, `NayaxMachineCombobox.vue`, `NayaxMappingStep.vue`, `NayaxMatchedTable.vue`, `NayaxMissingInDbTable.vue`, `NayaxResultsView.vue`, `NayaxSettingsStep.vue`, `NayaxUnmappedSection.vue`, `NayaxUploadStep.vue`. Confirm `NayaxMissingInDbTable.vue` and `NayaxGhostInDbTable.vue` exist (they're the ones being deleted).

---

## Chunk 1: Refactor results UI

Single coherent chunk because all the changes are tightly coupled (one new component depends on i18n keys, the orchestrator depends on the new component, etc.). One commit at the end.

### Task 1: Add new i18n keys to both locale files

**Files:**
- Modify: `management-frontend/i18n/locales/de.json`
- Modify: `management-frontend/i18n/locales/en.json`

The new component needs three new section/badge keys and one new empty-state key. We add them now so they're available when the component compiles in Task 3.

- [ ] **Step 1.1: Add the keys to German**

Open `management-frontend/i18n/locales/de.json`. Find the `nayax.reconcile.results.*` block (search for `"matchedShort"`). The block already contains `matchedShort`, `missingShort`, `ghostShort`, `matchedTitle`, `missingTitle`, `ghostTitle`, `otherTitle`, etc.

After the existing `otherTitle` line, add four new keys (preserve existing keys — do not delete `missingTitle`, `ghostTitle`, `allMatched`, or `noGhosts`; they become orphans, intentional per spec):

```json
        "differencesTitle": "Abweichungen",
        "bucketMissing": "Fehlt in DB",
        "bucketGhost": "Nur in DB",
        "noDifferences": "Keine Abweichungen gefunden.",
```

- [ ] **Step 1.2: Add the keys to English**

In `management-frontend/i18n/locales/en.json`, mirror the placement and add:

```json
        "differencesTitle": "Differences",
        "bucketMissing": "Missing in DB",
        "bucketGhost": "DB only",
        "noDifferences": "No differences found.",
```

- [ ] **Step 1.3: Verify both JSON files still parse**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
python3 -c "import json; json.load(open('i18n/locales/de.json')); print('de.json OK')"
python3 -c "import json; json.load(open('i18n/locales/en.json')); print('en.json OK')"
```

Expected: `de.json OK` and `en.json OK` printed. Any syntax error would surface here.

- [ ] **Step 1.4: Verify the keys are reachable**

```bash
python3 -c "import json; d=json.load(open('i18n/locales/de.json')); r=d['nayax']['reconcile']['results']; print({k: r.get(k) for k in ('differencesTitle', 'bucketMissing', 'bucketGhost', 'noDifferences')})"
```

Expected output shows all four German strings populated.

```bash
python3 -c "import json; d=json.load(open('i18n/locales/en.json')); r=d['nayax']['reconcile']['results']; print({k: r.get(k) for k in ('differencesTitle', 'bucketMissing', 'bucketGhost', 'noDifferences')})"
```

Expected output shows all four English strings populated.

### Task 2: Update `NayaxMatchedTable.vue` to use `formatDateTime`

**Files:**
- Modify: `management-frontend/app/components/nayax/NayaxMatchedTable.vue`

The Matched table currently renders `m.nayax.localDt` as the raw Nayax string. To keep all three result-section tables consistent in date format (and to match the Differences table we're about to build), route it through the same `formatDateTime(iso, locale)` helper everything else in the app uses.

- [ ] **Step 2.1: Read the current file**

```bash
cat /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/components/nayax/NayaxMatchedTable.vue
```

Note the existing import section and the `<td>` cell currently rendering `m.nayax.localDt`. After Chunk 6 + the chunk-6 fixes, this file already imports `formatCurrency` and uses `useI18n()` — but it does NOT yet import `formatDateTime` or destructure `locale`. Verify and adjust.

- [ ] **Step 2.2: Add the import for `formatDateTime` and destructure `locale`**

In the `<script setup>` block, find the existing import line that imports `formatCurrency`:

```ts
import { formatCurrency } from '@/lib/utils'
```

Replace with:

```ts
import { formatCurrency, formatDateTime } from '@/lib/utils'
```

Find the line `const { t } = useI18n()`. Replace with:

```ts
const { t, locale } = useI18n()
```

- [ ] **Step 2.3: Replace the time cell**

In the `<template>` block, find the `<td>` that currently renders the time. It looks like:

```html
<td class="px-4 py-2">{{ m.nayax.localDt }}</td>
```

Replace with:

```html
<td class="px-4 py-2">{{ formatDateTime(m.nayax.utcDt, locale) }}</td>
```

**Important — do NOT touch the composable's `exportDiffCsv`.** The CSV still emits `m.nayax.localDt` as the raw Nayax string in the `nayax_time_local` column. That's deliberate so the CSV documents the source-file timestamp verbatim. This change is purely UI rendering.

- [ ] **Step 2.4: Type-check**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npx vue-tsc --noEmit 2>&1 | grep NayaxMatchedTable | head -5
```

Expected: no output.

### Task 3: Create `NayaxDifferencesTable.vue`

**Files:**
- Create: `management-frontend/app/components/nayax/NayaxDifferencesTable.vue`

This is the meat of the refactor. The new component takes both `missing` and `ghosts` arrays, merges them chronologically, and renders one unified table with bucket badges. It owns the bulk-import selection state and the per-row delete confirmation — the same logic that was split across the two now-deleted components.

- [ ] **Step 3.1: Create the file with full content**

Create `management-frontend/app/components/nayax/NayaxDifferencesTable.vue` with the following content:

```html
<script setup lang="ts">
import { computed, ref } from 'vue'
import type { NayaxRow, DbSale } from '~/composables/useNayaxReconciliation'
import { formatCurrency, formatDateTime } from '@/lib/utils'
import { IconAlertTriangle, IconChevronDown, IconChevronRight, IconInfoCircle, IconTrash } from '@tabler/icons-vue'
import AppModal from '~/components/AppModal.vue'

const props = defineProps<{
  missing: NayaxRow[]
  ghosts: DbSale[]
  machineNameByVmId: Map<string, string>
  isAdmin: boolean
  open: boolean
}>()
defineEmits<{ toggle: [] }>()

const { t, locale } = useI18n()
const recon = useNayaxReconciliation()

// Bulk-import selection (only Missing rows are selectable).
const selected = ref<Set<string>>(new Set())
const showConfirm = ref(false)
const lastResult = ref<{ imported: number; errors: string[] } | null>(null)
const pendingDelete = ref<DbSale | null>(null)

const showDeleteConfirm = computed({
  get: () => pendingDelete.value !== null,
  set: (v: boolean) => { if (!v) pendingDelete.value = null },
})

// Chronologically merged rows. Both NayaxRow.utcDt and DbSale.created_at are
// ISO 8601 with a 'Z' suffix, so lexicographic localeCompare is chronological.
// Stable tiebreaker: at identical timestamps, the missing-in-DB row comes
// before the ghost row (the Nayax-recorded event first).
type Row =
  | { kind: 'missing'; ts: string; payload: NayaxRow }
  | { kind: 'ghost'; ts: string; payload: DbSale }

const mergedRows = computed<Row[]>(() => {
  const rows: Row[] = [
    ...props.missing.map(m => ({ kind: 'missing' as const, ts: m.utcDt, payload: m })),
    ...props.ghosts.map(g => ({ kind: 'ghost' as const, ts: g.created_at, payload: g })),
  ]
  rows.sort((a, b) =>
    a.ts.localeCompare(b.ts) || (a.kind === 'missing' ? -1 : 1),
  )
  return rows
})

const total = computed(() => props.missing.length + props.ghosts.length)
const allMissingSelected = computed(() =>
  props.missing.length > 0 && selected.value.size === props.missing.length,
)

function toggleOne(txId: string) {
  if (selected.value.has(txId)) selected.value.delete(txId)
  else selected.value.add(txId)
  // Force reactivity — Vue does not observe Set.add/delete in-place.
  selected.value = new Set(selected.value)
}

function toggleAllMissing() {
  if (allMissingSelected.value) selected.value = new Set()
  else selected.value = new Set(props.missing.map(r => r.txId))
}

async function runImport() {
  const rowsToImport = props.missing.filter(r => selected.value.has(r.txId))
  if (rowsToImport.length === 0) return
  showConfirm.value = false
  lastResult.value = await recon.bulkImportMissing(rowsToImport)
  selected.value = new Set()
}

async function confirmDelete() {
  if (!pendingDelete.value) return
  const id = pendingDelete.value.id
  pendingDelete.value = null
  await recon.deleteGhost(id)
}

function ghostMachineName(g: DbSale): string {
  return props.machineNameByVmId.get(g.machine_id) ?? '—'
}
function shortId(id: string): string {
  return id.slice(0, 8)
}
</script>

<template>
  <div class="rounded-xl border bg-card shadow-sm">
    <button class="flex w-full items-center justify-between p-4 hover:bg-muted/30" @click="$emit('toggle')">
      <span class="flex items-center gap-2 text-sm font-medium">
        <IconAlertTriangle class="h-4 w-4 text-muted-foreground" />
        {{ t('nayax.reconcile.results.differencesTitle') }} ({{ total }})
      </span>
      <component :is="open ? IconChevronDown : IconChevronRight" class="h-4 w-4 text-muted-foreground" />
    </button>

    <div v-if="open" class="border-t">
      <!-- Bulk action bar (only for admins with selected missing rows) -->
      <div v-if="selected.size > 0 && isAdmin" class="flex items-center justify-between bg-muted/40 px-4 py-2 text-sm">
        <span>{{ t('nayax.reconcile.results.selectedN', { n: selected.size }) }}</span>
        <button
          class="inline-flex h-8 items-center rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
          @click="showConfirm = true"
        >
          {{ t('nayax.reconcile.results.importCta') }}
        </button>
      </div>

      <!-- Import result banner -->
      <div
        v-if="lastResult"
        class="border-b px-4 py-2 text-sm"
        :class="lastResult.errors.length > 0
          ? 'bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-200'
          : 'bg-green-50 text-green-800 dark:bg-green-950 dark:text-green-200'"
      >
        <p>
          {{ t('nayax.reconcile.results.importedN', { n: lastResult.imported }) }}
          <span v-if="lastResult.errors.length > 0"> · {{ t('nayax.reconcile.results.importErrors', { n: lastResult.errors.length }) }}</span>
        </p>
        <details v-if="lastResult.errors.length > 0" class="mt-2">
          <summary class="cursor-pointer text-xs underline">{{ t('nayax.reconcile.results.showErrors') }}</summary>
          <ul class="mt-1 list-disc pl-5 text-xs space-y-0.5">
            <li v-for="(err, i) in lastResult.errors" :key="i" class="font-mono">{{ err }}</li>
          </ul>
        </details>
      </div>

      <!-- Empty state -->
      <div v-if="total === 0" class="p-4 text-sm text-muted-foreground">
        {{ t('nayax.reconcile.results.noDifferences') }}
      </div>

      <!-- Merged table -->
      <div v-else class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b bg-muted/40 text-left">
              <th class="w-10 px-4 py-2">
                <input
                  v-if="missing.length > 0"
                  type="checkbox"
                  :checked="allMissingSelected"
                  :disabled="!isAdmin"
                  :aria-label="t('nayax.reconcile.results.selectedN', { n: missing.length })"
                  @change="toggleAllMissing"
                />
              </th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTime') }}</th>
              <th class="px-4 py-2 font-medium"></th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colMachine') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colSlot') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colProduct') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPrice') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colPayment') }}</th>
              <th class="px-4 py-2 font-medium">{{ t('nayax.reconcile.results.colTxId') }}</th>
              <th class="w-20 px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <template v-for="row in mergedRows" :key="row.kind + ':' + (row.kind === 'missing' ? row.payload.txId : row.payload.id)">
              <!-- Missing row -->
              <tr v-if="row.kind === 'missing'" class="border-b last:border-0">
                <td class="px-4 py-2">
                  <input
                    type="checkbox"
                    :checked="selected.has(row.payload.txId)"
                    :disabled="!isAdmin"
                    @change="toggleOne(row.payload.txId)"
                  />
                </td>
                <td class="px-4 py-2">{{ formatDateTime(row.payload.utcDt, locale) }}</td>
                <td class="px-4 py-2">
                  <span class="inline-flex items-center rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-950 dark:text-red-200">
                    {{ t('nayax.reconcile.results.bucketMissing') }}
                  </span>
                </td>
                <td class="px-4 py-2">{{ row.payload.machineName }}</td>
                <td class="px-4 py-2 tabular-nums">{{ row.payload.itemNumber }}</td>
                <td class="px-4 py-2">{{ row.payload.productName }}</td>
                <td class="px-4 py-2 tabular-nums">{{ formatCurrency(row.payload.priceGross, locale) }}</td>
                <td class="px-4 py-2">{{ row.payload.paymentSource }}</td>
                <td class="px-4 py-2 font-mono text-xs">{{ row.payload.txId }}</td>
                <td class="px-4 py-2"></td>
              </tr>
              <!-- Ghost row -->
              <tr v-else class="border-b last:border-0">
                <td class="px-4 py-2"><span class="text-muted-foreground">—</span></td>
                <td class="px-4 py-2">{{ formatDateTime(row.payload.created_at, locale) }}</td>
                <td class="px-4 py-2">
                  <span class="inline-flex items-center rounded-full bg-yellow-100 px-2 py-0.5 text-xs font-medium text-yellow-800 dark:bg-yellow-950 dark:text-yellow-200">
                    <IconInfoCircle class="mr-1 h-3 w-3" />
                    {{ t('nayax.reconcile.results.bucketGhost') }}
                  </span>
                </td>
                <td class="px-4 py-2">{{ ghostMachineName(row.payload) }}</td>
                <td class="px-4 py-2 tabular-nums">{{ row.payload.item_number ?? '—' }}</td>
                <td class="px-4 py-2">{{ row.payload.product_name ?? '—' }}</td>
                <td class="px-4 py-2 tabular-nums">{{ formatCurrency(row.payload.item_price ?? null, locale) }}</td>
                <td class="px-4 py-2">{{ row.payload.channel ?? '—' }}</td>
                <td class="px-4 py-2 font-mono text-xs">{{ shortId(row.payload.id) }}</td>
                <td class="px-4 py-2 text-right">
                  <button
                    v-if="isAdmin"
                    class="inline-flex h-8 items-center gap-1 rounded-md border border-red-200 px-2 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-300 dark:hover:bg-red-950"
                    @click="pendingDelete = row.payload"
                  >
                    <IconTrash class="h-3 w-3" />
                    {{ t('common.delete') }}
                  </button>
                </td>
              </tr>
            </template>
          </tbody>
        </table>
      </div>
    </div>

    <!-- Bulk-import confirmation -->
    <AppModal v-model:open="showConfirm" :title="t('nayax.reconcile.results.importConfirmTitle')" size="sm">
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
    </AppModal>

    <!-- Per-row delete confirmation -->
    <AppModal v-model:open="showDeleteConfirm" :title="t('nayax.reconcile.results.deleteConfirmTitle')" size="sm">
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
    </AppModal>
  </div>
</template>
```

- [ ] **Step 3.2: Type-check the new file**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npx vue-tsc --noEmit 2>&1 | grep NayaxDifferencesTable | head -10
```

Expected: no output. If you see errors:
- "Property X does not exist" → check the `NayaxRow` / `DbSale` field names against `app/composables/useNayaxReconciliation.ts` (lines ~54-99 — the type exports).
- "Cannot find module '~/components/AppModal.vue'" → the `~/` alias is configured in `nuxt.config.ts` and known to work for other components — confirm spelling.
- "ResolvedComponentInstance" issues on `AppModal` `v-model:open` → verify `AppModal` exposes that exact API by reading its `<script setup>` block; the project's other modals (e.g. `NayaxGhostInDbTable.vue`'s soon-to-be-deleted modal) use the same pattern after the chunk-6 fix.

### Task 4: Update `NayaxResultsView.vue` to use the new component

**Files:**
- Modify: `management-frontend/app/components/nayax/NayaxResultsView.vue`

The orchestrator currently imports + renders `NayaxMissingInDbTable` and `NayaxGhostInDbTable` separately. Replace with the new merged component, and compute `machineNameByVmId` once for the new component to consume.

- [ ] **Step 4.1: Read the current file**

```bash
cat /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/components/nayax/NayaxResultsView.vue
```

Note the structure: imports, refs for the four section open-states (`matchedOpen`, `missingOpen`, `ghostOpen`, `otherOpen`), template with the four sections.

- [ ] **Step 4.2: Update the imports**

In the `<script setup>` block, find the lines that import the two old components:

```ts
import NayaxMissingInDbTable from './NayaxMissingInDbTable.vue'
import NayaxGhostInDbTable from './NayaxGhostInDbTable.vue'
```

Replace both with a single import:

```ts
import NayaxDifferencesTable from './NayaxDifferencesTable.vue'
```

- [ ] **Step 4.3: Consolidate the open-state refs and add the machine-name lookup**

In the `<script setup>` block, find the ref declarations:

```ts
const matchedOpen = ref(false)
const missingOpen = ref(true)
const ghostOpen = ref(true)
const otherOpen = ref(true)
```

Replace with:

```ts
const matchedOpen = ref(false)
const diffOpen = ref(true)
const otherOpen = ref(true)

// Reverse-index vmId → machineName, derived from any Nayax row that
// referenced that VM. Used by NayaxDifferencesTable to show a human
// name on ghost rows (which only carry machine_id). Falls back to '—'
// inside the component when a ghost is on a machine that the current
// Nayax file didn't touch.
const machineNameByVmId = computed(() => {
  const map = new Map<string, string>()
  for (const n of recon.rawRows.value) {
    const vmId = recon.mapping.value[n.nayaxMachineId]
    if (vmId && !map.has(vmId)) {
      map.set(vmId, n.machineName)
    }
  }
  return map
})
```

If `computed` isn't already imported in the existing file, add it: change the existing `import { ref } from 'vue'` (or similar) to include `computed`.

- [ ] **Step 4.4: Replace the two section blocks in the template**

In the `<template>` block, find the two adjacent section blocks rendering the old components. They look like:

```html
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
```

Replace BOTH with the single merged section:

```html
<!-- Merged differences (focus bucket) -->
<NayaxDifferencesTable
  :missing="result.missingInDb"
  :ghosts="result.ghostInDb"
  :machine-name-by-vm-id="machineNameByVmId"
  :is-admin="isAdmin"
  :open="diffOpen"
  @toggle="diffOpen = !diffOpen"
/>
```

The Matched and Unmapped sections below stay exactly as they were.

- [ ] **Step 4.5: Type-check**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npx vue-tsc --noEmit 2>&1 | grep -E "Nayax(ResultsView|DifferencesTable)" | head -10
```

Expected: no output. If you see "missingOpen is undefined" or "ghostOpen is undefined" type errors, double-check that no template fragment still references the deleted refs.

### Task 5: Delete the two now-unused component files

**Files:**
- Delete: `management-frontend/app/components/nayax/NayaxMissingInDbTable.vue`
- Delete: `management-frontend/app/components/nayax/NayaxGhostInDbTable.vue`

- [ ] **Step 5.1: Confirm nothing else imports them**

```bash
grep -rn "NayaxMissingInDbTable\|NayaxGhostInDbTable" /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/ 2>/dev/null
```

Expected: only matches inside the two files themselves (their own `<script setup>` definitions). Zero matches in other files. If anything else still imports them, the previous task missed an edit — fix that first.

- [ ] **Step 5.2: Delete the files**

```bash
rm /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/components/nayax/NayaxMissingInDbTable.vue
rm /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/components/nayax/NayaxGhostInDbTable.vue
```

- [ ] **Step 5.3: Verify the nayax components directory now contains the expected set**

```bash
ls /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/components/nayax/
```

Expected files: `NayaxDifferencesTable.vue`, `NayaxMachineCombobox.vue`, `NayaxMappingStep.vue`, `NayaxMatchedTable.vue`, `NayaxResultsView.vue`, `NayaxSettingsStep.vue`, `NayaxUnmappedSection.vue`, `NayaxUploadStep.vue` — 8 files, with `NayaxDifferencesTable` replacing the two deleted ones.

### Task 6: Full verification

- [ ] **Step 6.1: Type-check the whole frontend**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npx vue-tsc --noEmit 2>&1 | tail -30
```

Expected: the trailing line count of errors should be **identical** to what `npx vue-tsc --noEmit` produced before this refactor (project has some pre-existing unrelated errors — pre-flight Step 0.1 baseline was 171). Specifically: zero new errors related to `Nayax*` files. Sanity-check by piping through `grep -i nayax`:

```bash
npx vue-tsc --noEmit 2>&1 | grep -i nayax | head -10
```

Expected: no output.

- [ ] **Step 6.2: Run the existing Vitest suite**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run test 2>&1 | tail -10
```

Expected: 141 tests pass (unchanged — the matcher and composable are untouched, and no test references the deleted components).

- [ ] **Step 6.3: Confirm both locale JSON files still parse**

```bash
python3 -c "import json; d=json.load(open('i18n/locales/de.json')); print('OK' if d['nayax']['reconcile']['results']['differencesTitle'] == 'Abweichungen' else 'WRONG')"
python3 -c "import json; d=json.load(open('i18n/locales/en.json')); print('OK' if d['nayax']['reconcile']['results']['differencesTitle'] == 'Differences' else 'WRONG')"
```

Expected: both print `OK`.

- [ ] **Step 6.4: Smoke test against the dev server (or fall back to curl)**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run dev
```

Manual: open `http://localhost:3000`, log in (credentials in `~/.claude/projects/-Users-lucienkerl-Development-mdb-esp32-cashless/memory/user_dev_credentials.md`), navigate to `/reports/nayax-reconciliation`, upload `tmp/nayax-sale.xlsx`, walk through to results. Verify:

1. There is ONE "Abweichungen" section (not two), with a combined count.
2. Rows are sorted chronologically — opening the section shows Nayax (red badge) and DB-only (yellow badge) rows interleaved by time.
3. Date format is consistent — both row types show the date the same way (e.g. `22.05.2026, 14:32:09`), not the raw Nayax string vs. browser locale.
4. The Matched section (collapsed by default) also uses the same date format when expanded.
5. Selecting two missing rows → bulk action bar appears → confirm modal opens → 2 sales import → banner shows "2 imported".
6. Per-row delete on a ghost → confirm modal opens → delete works.
7. Empty case: if every Nayax row matched, the Abweichungen section opens to `Keine Abweichungen gefunden.`

If the dev environment's edge-function DNS is broken (same as during earlier chunks), do the equivalent programmatic check:

```bash
curl -sI http://localhost:3000/reports/nayax-reconciliation
```

Expected: `HTTP/1.1 302` redirect to `/auth/login` (page rendered, auth middleware fired, no SSR errors).

Check the dev-server console output for Vue compilation errors related to the new component — there should be none.

### Task 7: Commit

- [ ] **Step 7.1: Confirm only the intended files are staged**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git status -s
```

Expected modifications + deletions:
- `M  management-frontend/app/components/nayax/NayaxMatchedTable.vue`
- `M  management-frontend/app/components/nayax/NayaxResultsView.vue`
- `D  management-frontend/app/components/nayax/NayaxMissingInDbTable.vue`
- `D  management-frontend/app/components/nayax/NayaxGhostInDbTable.vue`
- `??  management-frontend/app/components/nayax/NayaxDifferencesTable.vue`
- `M  management-frontend/i18n/locales/de.json`
- `M  management-frontend/i18n/locales/en.json`

Pre-existing dirty files (`android/local.properties`, `ios/NotificationService/Info.plist`, `ios/VMflow/Resources/Info.plist`) and the untracked `tmp/` directory should be left untouched — do not stage them.

- [ ] **Step 7.2: Stage the intended files only**

```bash
git add \
  management-frontend/app/components/nayax/NayaxMatchedTable.vue \
  management-frontend/app/components/nayax/NayaxResultsView.vue \
  management-frontend/app/components/nayax/NayaxDifferencesTable.vue \
  management-frontend/i18n/locales/de.json \
  management-frontend/i18n/locales/en.json
git rm \
  management-frontend/app/components/nayax/NayaxMissingInDbTable.vue \
  management-frontend/app/components/nayax/NayaxGhostInDbTable.vue
```

`git rm` records the deletion as part of the same staged set. Verify with `git diff --cached --stat` — expect 4 modifications (NayaxMatchedTable.vue, NayaxResultsView.vue, de.json, en.json) + 2 deletions (NayaxMissingInDbTable.vue, NayaxGhostInDbTable.vue) + 1 new file (NayaxDifferencesTable.vue), ~250 insertions and ~250 deletions.

- [ ] **Step 7.3: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor(reconcile): merge missing+ghost into chronological diff view

UI-only refactor of the Results step. Replaces NayaxMissingInDbTable +
NayaxGhostInDbTable with a single NayaxDifferencesTable that renders
both buckets interleaved chronologically (sort key: UTC ISO timestamp,
tiebreaker prefers Missing). Each row carries a coloured bucket badge
(red "Fehlt in DB" / yellow "Nur in DB") so near-miss pairs are
immediately visible side-by-side.

All result tables (Matched + Differences) now use formatDateTime via
the i18n locale — was mixed raw Nayax string vs. browser-locale string.
exportDiffCsv keeps emitting the raw Nayax localDt in the CSV column
on purpose; this change is purely UI render.

Composable, matcher, CSV, DB unchanged. New i18n keys:
nayax.reconcile.results.{differencesTitle,bucketMissing,bucketGhost,
noDifferences}.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7.4: Final sanity check**

```bash
git log -1 --stat
```

Expected: the new commit at HEAD with the 8 files (5 modified, 2 deleted, 1 created) listed in the stat output.

---

## Done

Acceptance criteria from the spec:

- [x] One merged "Abweichungen" section replaces the two old sections
- [x] Rows sorted chronologically by UTC timestamp with deterministic tiebreaker
- [x] Per-row bucket badge (red Missing / yellow Ghost) so they're visually distinct
- [x] Both row types render dates via `formatDateTime(iso, locale)` — identical format
- [x] Matched table also uses the same date format
- [x] Bulk import (Missing only) and per-row delete (Ghost only) preserved
- [x] Empty state shows `noDifferences`
- [x] CSV export unchanged
- [x] Composable / matcher / DB unchanged
- [x] 141 unit tests still pass
