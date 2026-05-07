# Kassenbuch Flow & Labels Redesign — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 1,110-line single-file Kassenbuch page with a flow-visualisation-first redesign: clear source/target action labels, a 3-station flow (In Automaten → In der Kasse → Letzte Bankeinzahlung), and per-Barkasse bank-deposit threshold — all without touching the GoBD hash chain.

**Architecture:** One additive DB column + frontend refactor. The current `pages/cash-book/index.vue` (1,110 lines) is decomposed into ~13 self-contained components in `components/cash-book/`. The composable `useCashBook` gains one computed (`lastBankDeposit`) and one CRUD method. Entry-type display labels change in i18n only — the `cash_book_entries.type` enum strings in the database stay exactly as they are, preserving every existing SHA256 hash.

**Tech Stack:** Nuxt 4 (`app/`), TypeScript, `@nuxtjs/supabase`, `@nuxtjs/i18n` (en/de), shadcn-nuxt, TailwindCSS 4, Supabase CLI for the local DB migration.

**Spec:** [docs/superpowers/specs/2026-05-07-kassenbuch-flow-redesign-design.md](../specs/2026-05-07-kassenbuch-flow-redesign-design.md)

**Verification model:** No component tests exist for the current Kassenbuch page; the codebase pattern is browser smoke tests. Each chunk ends with a smoke step that exercises the page in the dev browser. Run `npm run dev` from `management-frontend/` once at the start; HMR picks up edits.

---

## Pre-flight

- [ ] **Step 0.1: Start the dev server**

```bash
cd management-frontend
npm install   # if not already done
npm run dev
```

Leave it running. Open `http://localhost:3000` and log in (credentials in `memory/user_dev_credentials.md`).

- [ ] **Step 0.2: Confirm baseline works**

Navigate to `/cash-book`. Confirm: at least one Barkasse exists in the dropdown, the 4 KPI cards render, the action button row is visible, and the entries table shows at least one row. If the page is broken on `main`, stop and ask before proceeding.

If no Barkasse exists yet, create one ("Test-Kasse", initial balance 0 €) so the rest of the plan has data to work with.

- [ ] **Step 0.3: Run i18n consumer audit**

```bash
grep -rEn 'cashBook\.(recordWithdrawal|recordPayout|typeWithdrawal|typePayout|totalWithdrawals)' management-frontend/app
```

Expected: matches only inside `management-frontend/app/pages/cash-book/index.vue`. Any other file found here gets the same wording update applied alongside the page rewrite (Chunk 6). Capture the output for reference.

---

## Chunk 1: Database migration

One additive column. Idempotent. Safe on existing rows because the default backfills automatically.

### Task 1: Add `bank_deposit_threshold` column

**Files:**
- Create: `Docker/supabase/migrations/20260507000000_bank_deposit_threshold.sql`

- [ ] **Step 1.1: Write the migration**

Create `Docker/supabase/migrations/20260507000000_bank_deposit_threshold.sql`:

```sql
-- =========================================================
-- Per-Barkasse threshold for highlighting the "Geld auf
-- Bank einzahlen" CTA. Default 500 EUR; minimum 1 EUR
-- enforced at the application layer.
-- =========================================================

ALTER TABLE public.cash_books
  ADD COLUMN IF NOT EXISTS bank_deposit_threshold float8 NOT NULL DEFAULT 500;
```

- [ ] **Step 1.2: Apply the migration**

```bash
cd Docker/supabase
supabase migration up
```

Expected output: `Applying migration 20260507000000_bank_deposit_threshold.sql...`

**Never** run `supabase db reset` — it would wipe the dev data.

- [ ] **Step 1.3: Verify the column exists**

```bash
psql "$(supabase status -o env | grep DB_URL | cut -d'=' -f2- | tr -d '"')" \
  -c "SELECT column_name, data_type, column_default FROM information_schema.columns WHERE table_name='cash_books' AND column_name='bank_deposit_threshold';"
```

Expected: one row with `data_type=double precision`, `column_default=500`.

Alternative if `psql` is awkward: open Supabase Studio at `http://localhost:54323`, Table Editor → `cash_books` → confirm the column with a default of 500 is present and existing rows show 500.

- [ ] **Step 1.4: Commit**

```bash
git add Docker/supabase/migrations/20260507000000_bank_deposit_threshold.sql
git commit -m "feat(cash-book): add bank_deposit_threshold column to cash_books"
```

---

## Chunk 2: i18n + composable foundations

These are read by every component we add later. Do them first so HMR doesn't show `[missing translation]` while the rest of the work happens.

### Task 2: Update i18n strings

**Files:**
- Modify: `management-frontend/i18n/locales/de.json` (lines ~1205–1277)
- Modify: `management-frontend/i18n/locales/en.json` (lines ~1205–1277)

- [ ] **Step 2.1: Update existing keys in `de.json`**

In the `cashBook` block, change these existing values:

```json
    "totalWithdrawals": "Aus Automaten gesamt",
    "recordWithdrawal": "Geld aus Automat entnehmen",
    "recordPayout": "Geld auf Bank einzahlen",
    "typeWithdrawal": "Aus Automat",
    "typePayout": "Bankeinzahlung",
```

(The keys themselves are unchanged; only the German values change.)

- [ ] **Step 2.2: Add new keys in `de.json`**

Inside the same `cashBook` block, add these new keys (anywhere within the block — keep alphabetic if you like):

```json
    "lastBankDeposit": "Letzte Bankeinzahlung",
    "noBankDepositYet": "Noch keine",
    "inMachines": "In Automaten",
    "inBox": "In der Kasse",
    "bankDepositThreshold": "Erinnerung an Bankeinzahlung ab Kassenstand",
    "thresholdHint": "Wenn der Kassenstand diesen Wert erreicht, wird der Button \"Auf Bank einzahlen\" hervorgehoben.",
    "thresholdMinimumHint": "Mindestens 1 €",
    "fullAmount": "Gesamten Bestand",
    "barkasseSettings": "Barkasse-Einstellungen",
    "expectedFromMachines": "Erwartet aus Automaten (seit letzter Entnahme)",
    "matchesExpected": "Stimmt mit Erwartung überein",
    "bookEntry": "Entnahme buchen",
    "bookDeposit": "Einzahlung buchen",
    "manage": "Verwalten",
    "more": "Mehr",
    "settings": "Einstellungen",
    "sinceDate": "seit {date}",
    "agoDays": "vor {n} Tagen"
```

- [ ] **Step 2.3: Mirror in `en.json`**

```json
    "totalWithdrawals": "Cash Collected from Machines",
    "recordWithdrawal": "Take cash from machine",
    "recordPayout": "Deposit to bank",
    "typeWithdrawal": "From machine",
    "typePayout": "Bank deposit",
```

```json
    "lastBankDeposit": "Last bank deposit",
    "noBankDepositYet": "None yet",
    "inMachines": "In machines",
    "inBox": "In cash box",
    "bankDepositThreshold": "Bank-deposit reminder threshold",
    "thresholdHint": "When the cash-box balance reaches this value, the \"Deposit to bank\" button is highlighted.",
    "thresholdMinimumHint": "Minimum €1",
    "fullAmount": "Full amount",
    "barkasseSettings": "Cash-box settings",
    "expectedFromMachines": "Expected from machines (since last withdrawal)",
    "matchesExpected": "Matches expected amount",
    "bookEntry": "Book withdrawal",
    "bookDeposit": "Book deposit",
    "manage": "Manage",
    "more": "More",
    "settings": "Settings",
    "sinceDate": "since {date}",
    "agoDays": "{n} days ago"
```

- [ ] **Step 2.4: Verify in browser**

Reload `/cash-book`. The button labels should now read "Geld aus Automat entnehmen" / "Geld auf Bank einzahlen" instead of "Entnahme erfassen" / "Auszahlung erfassen". Existing entries in the table should show "Aus Automat" / "Bankeinzahlung" badges. Toggle the language switcher to confirm both locales work.

If you see `[missing translation: cashBook.X]`, the key is misspelled — fix it before continuing.

- [ ] **Step 2.5: Commit**

```bash
git add management-frontend/i18n/locales/de.json management-frontend/i18n/locales/en.json
git commit -m "i18n(cash-book): rename action and entry-type labels to source/target wording"
```

### Task 3: Extend `useCashBook` composable

**Files:**
- Modify: `management-frontend/app/composables/useCashBook.ts`

- [ ] **Step 3.1: Add `bank_deposit_threshold` to the `CashBook` interface**

In `management-frontend/app/composables/useCashBook.ts`, update the interface near line 3:

```ts
export interface CashBook {
  id: string
  created_at: string
  company_id: string
  name: string
  initial_balance: number
  bank_deposit_threshold: number   // ← NEW
  activated_at: string
  created_by: string
  is_active: boolean
}
```

- [ ] **Step 3.2: Add `lastBankDeposit` computed**

Inside the `useCashBook` function, after the existing `totalCorrections` computed (around line 372–378), add:

```ts
  // Most recent non-reversed bank deposit. Invariant: `entries.value` is
  // sorted DESC by `entry_number` (set by fetchEntries' .order(..., desc)),
  // so the first match is the most recent one.
  const lastBankDeposit = computed<CashBookEntry | null>(() =>
    entries.value.find(e => e.type === 'payout' && !e.is_reversed) ?? null
  )
```

- [ ] **Step 3.3: Add `updateBankDepositThreshold` method**

Inside `useCashBook`, after the existing `unassignMachine` method (around line 326), add:

```ts
  async function updateBankDepositThreshold(cashBookId: string, threshold: number) {
    if (threshold < 1) {
      throw new Error('Schwellenwert muss mindestens 1 € sein')
    }
    const { error } = await (supabase as any)
      .from('cash_books')
      .update({ bank_deposit_threshold: threshold })
      .eq('id', cashBookId)

    if (error) throw error

    // Update local state
    const cb = cashBooks.value.find(c => c.id === cashBookId)
    if (cb) cb.bank_deposit_threshold = threshold
    if (selectedCashBook.value?.id === cashBookId) {
      selectedCashBook.value = { ...selectedCashBook.value, bank_deposit_threshold: threshold }
    }

    await logActivity('cash_book_threshold_updated', cashBookId, { threshold })
  }
```

- [ ] **Step 3.4: Export the new ref + method**

In the `return { ... }` block at the bottom, add `lastBankDeposit` next to the other computeds and `updateBankDepositThreshold` next to the other CRUD methods:

```ts
    // Computed KPIs
    currentBalance,
    totalWithdrawals,
    totalCorrections,
    lastBankDeposit,                  // ← NEW

    // Threshold
    updateBankDepositThreshold,       // ← NEW
```

- [ ] **Step 3.5: Type-check and verify**

```bash
cd management-frontend
npx nuxi typecheck
```

Expected: no errors.

In the browser, refresh `/cash-book`. The page should still render — the additions are non-breaking.

- [ ] **Step 3.6: Commit**

```bash
git add management-frontend/app/composables/useCashBook.ts
git commit -m "feat(cash-book): extend useCashBook with bank-deposit threshold and lastBankDeposit"
```

---

## Chunk 3: Extract leaf modals

The current page contains 7 inline modals. Each move is mechanical: cut the `<AppModal>` block from the page, paste into a new SFC, replace with `<NewModal v-model:open="..." />`. We do them one at a time, verifying each in the browser before the next.

**Files in this chunk:**
- Create: `management-frontend/app/components/cash-book/WithdrawalModal.vue`
- Create: `management-frontend/app/components/cash-book/BankDepositModal.vue`
- Create: `management-frontend/app/components/cash-book/CorrectionModal.vue`
- Create: `management-frontend/app/components/cash-book/ReversalModal.vue`
- Create: `management-frontend/app/components/cash-book/AssignMachinesModal.vue`
- Create: `management-frontend/app/components/cash-book/DeleteBarkasseModal.vue`
- Create: `management-frontend/app/components/cash-book/CreateBarkasseModal.vue`
- Modify: `management-frontend/app/pages/cash-book/index.vue`

> **Auto-import:** Nuxt 4 turns `app/components/cash-book/WithdrawalModal.vue` into `<CashBookWithdrawalModal />` automatically. Use the prefixed name in the page template.

### Task 4: Extract `WithdrawalModal`

- [ ] **Step 4.1: Create the component**

Create `management-frontend/app/components/cash-book/WithdrawalModal.vue`:

```vue
<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'
import type { TheoreticalCash, VendingMachineBasic } from '@/composables/useCashBook'

const props = defineProps<{
  open: boolean
  theoreticalCash: TheoreticalCash | null
  assignedMachines: VendingMachineBasic[]
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { counted: number; expected: number; machineId: string | null; description: string }): void
}>()

const { t } = useI18n()

const form = ref({
  counted_amount: 0,
  description: 'Geldentnahme aus Automat',
  machine_id: null as string | null,
})
const loading = ref(false)

const difference = computed(() => {
  if (!props.theoreticalCash) return 0
  return form.value.counted_amount - props.theoreticalCash.cash_sales_since
})

watch(() => props.open, (now) => {
  if (now) {
    form.value = { counted_amount: 0, description: 'Geldentnahme aus Automat', machine_id: null }
  }
})

async function onSubmit() {
  loading.value = true
  try {
    emit('submit', {
      counted: form.value.counted_amount,
      expected: props.theoreticalCash?.cash_sales_since ?? 0,
      machineId: form.value.machine_id,
      description: form.value.description,
    })
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordWithdrawal')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div class="rounded-lg border bg-muted/50 p-3">
        <div class="text-sm text-muted-foreground">{{ t('cashBook.expectedFromMachines') }}</div>
        <div class="text-lg font-bold tabular-nums">
          {{ theoreticalCash ? formatCurrency(theoreticalCash.cash_sales_since) : '—' }}
        </div>
        <div v-if="theoreticalCash?.machines?.length" class="mt-2 space-y-0.5">
          <div v-for="m in theoreticalCash.machines" :key="m.machine_id" class="text-xs text-muted-foreground">
            {{ m.machine_name || 'Automat' }}: +{{ formatCurrency(m.cash_sales) }}
          </div>
        </div>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.countedAmount') }} (EUR)</label>
        <input
          v-model.number="form.counted_amount"
          type="number" step="0.01" min="0" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div
        v-if="form.counted_amount > 0 && theoreticalCash"
        class="rounded-lg p-3 text-sm"
        :class="Math.abs(difference) > 0.001
          ? 'border border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-800 dark:bg-amber-900/20 dark:text-amber-400'
          : 'border border-green-200 bg-green-50 text-green-700 dark:border-green-800 dark:bg-green-900/20 dark:text-green-400'"
      >
        <template v-if="Math.abs(difference) > 0.001">
          {{ t('cashBook.differenceLabel') }}: {{ formatCurrency(difference) }}
        </template>
        <template v-else>
          ✓ {{ t('cashBook.matchesExpected') }}
        </template>
      </div>

      <div v-if="assignedMachines.length > 0">
        <label class="text-sm font-medium">{{ t('cashBook.fromMachine') }}</label>
        <select
          v-model="form.machine_id"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option :value="null">—</option>
          <option v-for="m in assignedMachines" :key="m.id" :value="m.id">
            {{ m.name || m.id.slice(0, 8) }}
          </option>
        </select>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
        <input
          v-model="form.description"
          type="text"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="flex justify-end gap-2">
        <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button type="submit" :disabled="loading || form.counted_amount <= 0"
                class="h-9 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50">
          {{ loading ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
```

- [ ] **Step 4.2: Wire it into the page**

In `management-frontend/app/pages/cash-book/index.vue`:

1. Replace the `<!-- Withdrawal Modal -->` `<AppModal>` block (~lines 866–941) with:
   ```vue
   <CashBookWithdrawalModal
     v-model:open="showWithdrawalModal"
     :theoretical-cash="theoreticalCash"
     :assigned-machines="assignedMachines"
     @submit="onWithdrawalSubmit"
   />
   ```
2. Replace the `submitWithdrawal` function with `onWithdrawalSubmit(payload)`:
   ```ts
   async function onWithdrawalSubmit(payload: { counted: number; expected: number; machineId: string | null; description: string }) {
     if (!selectedCashBook.value) return
     try {
       await createEntry({
         cash_book_id: selectedCashBook.value.id,
         type: 'withdrawal',
         amount: payload.counted,
         description: payload.description,
         machine_id: payload.machineId || null,
         counted_amount: payload.counted,
         expected_amount: payload.expected,
       })
       showWithdrawalModal.value = false
     } catch (err: any) {
       errorMessage.value = err.message
     }
   }
   ```
3. Delete the old `withdrawalForm`, `withdrawalLoading`, `withdrawalDifference`, `openWithdrawalModal`, `submitWithdrawal` refs/functions. Keep `showWithdrawalModal` (still controls the modal) and update the action button click to `@click="showWithdrawalModal = true"` so the child handles the rest.
4. Wait — `openWithdrawalModal` also re-fetches theoretical cash before opening. Keep that logic but make it a tiny helper:
   ```ts
   async function openWithdrawal() {
     if (selectedCashBook.value) await fetchTheoreticalCash(selectedCashBook.value.id)
     showWithdrawalModal.value = true
   }
   ```
   and use `@click="openWithdrawal"` on the button.

- [ ] **Step 4.3: Verify in browser**

Reload `/cash-book`. Click "Geld aus Automat entnehmen". The modal should:
- Open with the new title
- Show "Erwartet aus Automaten" with the per-machine breakdown
- Show the green "✓ Stimmt mit Erwartung überein" banner when counted equals expected
- Show the amber "Differenz" banner when counted differs
- Submit successfully and add a new entry

- [ ] **Step 4.4: Commit**

```bash
git add management-frontend/app/components/cash-book/WithdrawalModal.vue \
        management-frontend/app/pages/cash-book/index.vue
git commit -m "refactor(cash-book): extract WithdrawalModal component"
```

### Task 5: Extract `BankDepositModal` (with new "Gesamten Bestand" button)

- [ ] **Step 5.1: Create the component**

Create `management-frontend/app/components/cash-book/BankDepositModal.vue`:

```vue
<script setup lang="ts">
import { formatCurrency } from '@/lib/utils'

const props = defineProps<{
  open: boolean
  currentBalance: number
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { amount: number; description: string }): void
}>()

const { t } = useI18n()

const form = ref({ amount: 0, description: 'Bankeinzahlung' })
const loading = ref(false)

watch(() => props.open, (now) => {
  if (now) form.value = { amount: 0, description: 'Bankeinzahlung' }
})

function fillFullAmount() {
  form.value.amount = props.currentBalance
}

async function onSubmit() {
  if (form.value.amount <= 0) return
  loading.value = true
  try {
    emit('submit', { amount: form.value.amount, description: form.value.description })
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordPayout')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div class="rounded-lg border bg-muted/50 p-3 text-sm">
        {{ t('cashBook.currentBalance') }}: <span class="font-semibold">{{ formatCurrency(currentBalance) }}</span>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.amount') }} (EUR)</label>
        <div class="mt-1 flex gap-2">
          <input
            v-model.number="form.amount"
            type="number" step="0.01" min="0.01" required
            class="h-9 flex-1 rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <button
            type="button"
            class="h-9 rounded-md border border-input px-3 text-sm font-medium hover:bg-accent whitespace-nowrap"
            @click="fillFullAmount"
          >
            {{ t('cashBook.fullAmount') }}
          </button>
        </div>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.description') }}</label>
        <input
          v-model="form.description"
          type="text"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="flex justify-end gap-2">
        <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button type="submit" :disabled="loading || form.amount <= 0"
                class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50">
          {{ loading ? t('common.loading') : t('cashBook.bookDeposit') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
```

- [ ] **Step 5.2: Wire it into the page**

Replace the `<!-- Payout Modal -->` block (~lines 982–1019) with:

```vue
<CashBookBankDepositModal
  v-model:open="showPayoutModal"
  :current-balance="currentBalance"
  @submit="onBankDepositSubmit"
/>
```

Replace the `submitPayout` function:

```ts
async function onBankDepositSubmit(payload: { amount: number; description: string }) {
  if (!selectedCashBook.value) return
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'payout',
      amount: -Math.abs(payload.amount),
      description: payload.description,
    })
    showPayoutModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  }
}
```

Delete the old `payoutForm`, `payoutLoading`, `submitPayout`. Keep `showPayoutModal`. Update the deposit button to `@click="showPayoutModal = true"`.

- [ ] **Step 5.3: Verify in browser**

Click "Geld auf Bank einzahlen". The modal should open with the new title, show the current balance, accept manual input, and the new "Gesamten Bestand" button must fill the amount field with the full balance. Submit and confirm a new entry appears with the new "Bankeinzahlung" badge.

- [ ] **Step 5.4: Commit**

```bash
git add management-frontend/app/components/cash-book/BankDepositModal.vue \
        management-frontend/app/pages/cash-book/index.vue
git commit -m "refactor(cash-book): extract BankDepositModal with full-amount quick-fill"
```

### Task 6: Extract `CorrectionModal`

- [ ] **Step 6.1: Create the component**

Create `management-frontend/app/components/cash-book/CorrectionModal.vue`. Same shape as the others — props `{ open: boolean }`, emits `submit { amount: number; description: string }` and `update:open`. Move template/logic from the page (~lines 944–979) verbatim, swap labels to use the existing i18n keys, no new behaviour.

- [ ] **Step 6.2: Wire it into the page**

Replace the inline `<!-- Correction Modal -->` block with `<CashBookCorrectionModal v-model:open="showCorrectionModal" @submit="onCorrectionSubmit" />`. Build `onCorrectionSubmit` from the existing `submitCorrection` body.

- [ ] **Step 6.3: Verify**

Click "Korrektur erfassen", enter +5,00 € with description "Test", submit. New row with green +5,00 € must appear in the table.

- [ ] **Step 6.4: Commit**

```bash
git add management-frontend/app/components/cash-book/CorrectionModal.vue \
        management-frontend/app/pages/cash-book/index.vue
git commit -m "refactor(cash-book): extract CorrectionModal component"
```

### Task 7: Extract `ReversalModal`

- [ ] **Step 7.1: Create the component**

Create `management-frontend/app/components/cash-book/ReversalModal.vue`. Props: `{ open: boolean; entry: CashBookEntry | null }`. Emits `confirm` (no payload — parent already has the entry ref) and `update:open`. Template lifted from `<!-- Reversal Confirmation Modal -->` (~lines 1022–1049). Use `typeLabel(entry.type)` and `formatAmount(entry.amount)` helpers — duplicate them inside the component (~10 lines) since they are just label maps.

- [ ] **Step 7.2: Wire it into the page**

Replace the inline modal with `<CashBookReversalModal v-model:open="showReversalConfirm" :entry="reversalTarget" @confirm="submitReversal" />`. Keep `submitReversal` and `openReversalConfirm` in the page — they do server work.

- [ ] **Step 7.3: Verify**

Click "Stornieren" on a non-initial entry. The confirmation modal must show the entry's type, amount, and description. Confirm — the original goes line-through and a `Storno` row appears.

- [ ] **Step 7.4: Commit**

```bash
git add management-frontend/app/components/cash-book/ReversalModal.vue \
        management-frontend/app/pages/cash-book/index.vue
git commit -m "refactor(cash-book): extract ReversalModal component"
```

### Task 8: Extract `AssignMachinesModal`

- [ ] **Step 8.1: Create the component**

Create `management-frontend/app/components/cash-book/AssignMachinesModal.vue`. Props: `{ open: boolean; loading: boolean; allMachines: VendingMachineBasic[]; selectedCashBookId: string; cashBooks: CashBook[] }`. Emits `toggle { machineId: string; currentCashBookId: string | null }` and `update:open`. Template lifted from `<!-- Machine Assignment Modal -->` (~lines 829–864).

- [ ] **Step 8.2: Wire it into the page**

Replace inline modal. Build `onMachineToggle` in the page calling `assignMachine` / `unassignMachine` based on current state, then refresh theoretical cash.

- [ ] **Step 8.3: Verify**

Click "Automaten verwalten" (the button label was "Automaten zuweisen" — leave as-is for this task; we relabel in Chunk 5). Toggle a machine on/off and confirm the badge "Zugewiesen zu: ..." updates correctly.

- [ ] **Step 8.4: Commit**

```bash
git add management-frontend/app/components/cash-book/AssignMachinesModal.vue \
        management-frontend/app/pages/cash-book/index.vue
git commit -m "refactor(cash-book): extract AssignMachinesModal component"
```

### Task 9: Extract `DeleteBarkasseModal`

- [ ] **Step 9.1: Create the component**

Create `management-frontend/app/components/cash-book/DeleteBarkasseModal.vue`. Props: `{ open: boolean; cashBookName: string; entryCount: number; loading: boolean }`. Emits `confirm` and `update:open`. Internal state for the 2-step `deleteStep` ref and `deleteConfirmName` lives **inside the component** — the page just opens it and reacts to confirm. Move ~lines 1052–1108.

- [ ] **Step 9.2: Wire it into the page**

Replace inline modal. Page keeps `confirmDelete` (it talks to Supabase). Drop `deleteStep`, `deleteConfirmName` from the page.

- [ ] **Step 9.3: Verify**

Click the red "Barkasse löschen" button (later moves into the ⋯ Mehr menu — for now still visible). Step 1 warning, then "Ich verstehe, weiter", then type the name, then "Endgültig löschen". Confirm the Barkasse disappears from the dropdown.

> **Caution:** if you only have one test Barkasse, **do not** delete it — back out at step 2. Otherwise the rest of the plan has nothing to work against. Re-create the Barkasse if you accidentally delete it.

- [ ] **Step 9.4: Commit**

```bash
git add management-frontend/app/components/cash-book/DeleteBarkasseModal.vue \
        management-frontend/app/pages/cash-book/index.vue
git commit -m "refactor(cash-book): extract DeleteBarkasseModal component"
```

### Task 10: Extract `CreateBarkasseModal` (with new threshold field)

- [ ] **Step 10.1: Create the component**

Create `management-frontend/app/components/cash-book/CreateBarkasseModal.vue`. Props: `{ open: boolean }`. Emits `submit { name: string; initialBalance: number; threshold: number }` and `update:open`. Template lifted from `<!-- Create Cash Book Modal -->` (~lines 783–826) with one extra field below "Anfangsbestand":

```vue
<div>
  <label class="text-sm font-medium">{{ t('cashBook.bankDepositThreshold') }} (EUR)</label>
  <input
    v-model.number="form.threshold"
    type="number" step="1" min="1"
    class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
  />
  <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.thresholdHint') }}</p>
</div>
```

Default form: `{ name: '', initial_balance: 0, threshold: 500 }`.

- [ ] **Step 10.2: Update `useCashBook.createCashBook` signature**

Modify the method to accept and persist the threshold:

```ts
async function createCashBook(name: string, initialBalance: number, threshold: number = 500) {
  // ... existing code ...
  const { data, error } = await (supabase as any)
    .from('cash_books')
    .insert({
      company_id: organization.value?.id,
      name,
      initial_balance: initialBalance,
      bank_deposit_threshold: threshold,    // ← NEW
      created_by: session.user.id,
    })
    .select()
    .single()
  // ... rest unchanged ...
}
```

- [ ] **Step 10.3: Wire it into the page**

Replace the inline modal. Page handler:

```ts
async function onCreateBarkasse(payload: { name: string; initialBalance: number; threshold: number }) {
  try {
    await createCashBook(payload.name, payload.initialBalance, payload.threshold)
    showCreateModal.value = false
    if (selectedCashBook.value) await loadCashBookData()
  } catch (err: any) {
    errorMessage.value = err.message
  }
}
```

- [ ] **Step 10.4: Verify**

Click "Neue Barkasse". The modal must now have a "Erinnerung an Bankeinzahlung ab Kassenstand" field with default 500. Create a test Barkasse "Plan-Test" with initial 0 and threshold 100. Confirm it appears in the dropdown. Open the Supabase Studio (`http://localhost:54323`) and verify the new row has `bank_deposit_threshold = 100`.

- [ ] **Step 10.5: Commit**

```bash
git add management-frontend/app/components/cash-book/CreateBarkasseModal.vue \
        management-frontend/app/composables/useCashBook.ts \
        management-frontend/app/pages/cash-book/index.vue
git commit -m "refactor(cash-book): extract CreateBarkasseModal with threshold field"
```

### Task 11: Add `BarkasseSettingsModal` (NEW)

- [ ] **Step 11.1: Create the component**

Create `management-frontend/app/components/cash-book/BarkasseSettingsModal.vue`:

```vue
<script setup lang="ts">
const props = defineProps<{
  open: boolean
  initialThreshold: number
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', threshold: number): void
}>()

const { t } = useI18n()
const threshold = ref(props.initialThreshold)
const loading = ref(false)

watch(() => props.open, (now) => {
  if (now) threshold.value = props.initialThreshold
})

async function onSubmit() {
  if (threshold.value < 1) return
  loading.value = true
  try {
    emit('submit', threshold.value)
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.barkasseSettings')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div>
        <label class="text-sm font-medium">{{ t('cashBook.bankDepositThreshold') }} (EUR)</label>
        <input
          v-model.number="threshold"
          type="number" step="1" min="1" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.thresholdHint') }}</p>
        <p class="mt-1 text-xs text-muted-foreground">{{ t('cashBook.thresholdMinimumHint') }}</p>
      </div>

      <div class="flex justify-end gap-2">
        <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button type="submit" :disabled="loading || threshold < 1"
                class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50">
          {{ loading ? t('common.loading') : t('common.save') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
```

The page wires this in Chunk 5 (along with the ⋯ Mehr menu that opens it). For now just the file exists.

- [ ] **Step 11.2: Commit**

```bash
git add management-frontend/app/components/cash-book/BarkasseSettingsModal.vue
git commit -m "feat(cash-book): add BarkasseSettingsModal for threshold editing"
```

---

## Chunk 4: Flow visualisation

The new visual centerpiece. Three station cards + two CTAs with symmetric amber-ring highlighting.

**Files in this chunk:**
- Create: `management-frontend/app/components/cash-book/StationInMachines.vue`
- Create: `management-frontend/app/components/cash-book/StationInBox.vue`
- Create: `management-frontend/app/components/cash-book/StationLastBankDeposit.vue`
- Create: `management-frontend/app/components/cash-book/FlowVisualisation.vue`
- Modify: `management-frontend/app/lib/utils.ts` (add small `relativeTime()` helper if not already present)

### Task 12: Build the three station cards

- [ ] **Step 12.1: Create `StationInMachines.vue`**

```vue
<script setup lang="ts">
import { IconBuildingStore } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency } from '@/lib/utils'
import type { TheoreticalCash } from '@/composables/useCashBook'

defineProps<{ theoreticalCash: TheoreticalCash | null }>()
const { t } = useI18n()
</script>

<template>
  <Card>
    <CardHeader>
      <CardDescription class="flex items-center gap-1.5">
        <IconBuildingStore class="size-4" />
        {{ t('cashBook.inMachines') }}
      </CardDescription>
      <CardTitle class="text-2xl font-semibold tabular-nums">
        {{ theoreticalCash ? formatCurrency(theoreticalCash.cash_sales_since) : '—' }}
      </CardTitle>
    </CardHeader>
    <div v-if="theoreticalCash?.machines?.length" class="px-6 pb-4 space-y-0.5 text-xs text-muted-foreground">
      <div v-for="m in theoreticalCash.machines" :key="m.machine_id" class="flex justify-between gap-2">
        <span class="truncate">{{ m.machine_name || 'Automat' }}</span>
        <span class="tabular-nums">+{{ formatCurrency(m.cash_sales) }}</span>
      </div>
    </div>
  </Card>
</template>
```

- [ ] **Step 12.2: Create `StationInBox.vue`**

```vue
<script setup lang="ts">
import { IconCash } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency, formatDate } from '@/lib/utils'

defineProps<{ currentBalance: number; lastEntryAt: string | null }>()
const { t } = useI18n()
</script>

<template>
  <Card>
    <CardHeader>
      <CardDescription class="flex items-center gap-1.5">
        <IconCash class="size-4" />
        {{ t('cashBook.inBox') }}
      </CardDescription>
      <CardTitle class="text-2xl font-semibold tabular-nums">
        {{ formatCurrency(currentBalance) }}
      </CardTitle>
    </CardHeader>
    <div v-if="lastEntryAt" class="px-6 pb-4 text-xs text-muted-foreground">
      {{ t('cashBook.sinceDate', { date: formatDate(lastEntryAt) }) }}
    </div>
  </Card>
</template>
```

- [ ] **Step 12.3: Create `StationLastBankDeposit.vue`**

```vue
<script setup lang="ts">
import { IconBuildingBank } from '@tabler/icons-vue'
import { Card, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { formatCurrency, formatDate } from '@/lib/utils'
import type { CashBookEntry } from '@/composables/useCashBook'

const props = defineProps<{ lastBankDeposit: CashBookEntry | null }>()
const { t } = useI18n()

const daysAgo = computed(() => {
  if (!props.lastBankDeposit) return null
  const ms = Date.now() - new Date(props.lastBankDeposit.created_at).getTime()
  return Math.floor(ms / (24 * 60 * 60 * 1000))
})
</script>

<template>
  <Card>
    <CardHeader>
      <CardDescription class="flex items-center gap-1.5">
        <IconBuildingBank class="size-4" />
        {{ t('cashBook.lastBankDeposit') }}
      </CardDescription>
      <CardTitle class="text-2xl font-semibold tabular-nums">
        <template v-if="lastBankDeposit">
          {{ formatCurrency(Math.abs(lastBankDeposit.amount)) }}
        </template>
        <template v-else>
          <span class="text-base font-normal text-muted-foreground">{{ t('cashBook.noBankDepositYet') }}</span>
        </template>
      </CardTitle>
    </CardHeader>
    <div v-if="lastBankDeposit && daysAgo !== null" class="px-6 pb-4 text-xs text-muted-foreground">
      {{ daysAgo === 0 ? t('common.today') : t('cashBook.agoDays', { n: daysAgo }) }}
      · {{ formatDate(lastBankDeposit.created_at) }}
    </div>
  </Card>
</template>
```

(`common.today` may already exist; if `[missing translation]` appears, add `"today": "Heute"` / `"today": "Today"` to the `common` block in both locales.)

- [ ] **Step 12.4: Commit**

```bash
git add management-frontend/app/components/cash-book/StationInMachines.vue \
        management-frontend/app/components/cash-book/StationInBox.vue \
        management-frontend/app/components/cash-book/StationLastBankDeposit.vue \
        management-frontend/i18n/locales/de.json \
        management-frontend/i18n/locales/en.json
git commit -m "feat(cash-book): add three flow-visualisation station cards"
```

### Task 13: Build `FlowVisualisation`

- [ ] **Step 13.1: Create the component**

Create `management-frontend/app/components/cash-book/FlowVisualisation.vue`:

```vue
<script setup lang="ts">
import { IconArrowDown, IconBuildingBank } from '@tabler/icons-vue'
import type { CashBookEntry, TheoreticalCash } from '@/composables/useCashBook'

const props = defineProps<{
  theoreticalCash: TheoreticalCash | null
  currentBalance: number
  lastEntryAt: string | null
  lastBankDeposit: CashBookEntry | null
  bankDepositThreshold: number
}>()

const emit = defineEmits<{
  (e: 'withdraw'): void
  (e: 'deposit'): void
}>()

const { t } = useI18n()

const withdrawalNeeded = computed(() =>
  (props.theoreticalCash?.cash_sales_since ?? 0) > 0
)

const depositNeeded = computed(() =>
  props.currentBalance >= props.bankDepositThreshold
)

const ringClass = 'ring-2 ring-amber-400/60 dark:ring-amber-500/60 animate-pulse'
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- Stations row (desktop) -->
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-3 sm:items-stretch">
      <CashBookStationInMachines :theoretical-cash="theoreticalCash" />

      <!-- Mobile arrow + button between station 1 and 2 -->
      <div class="flex flex-col items-center gap-2 sm:hidden">
        <IconArrowDown class="size-5 text-muted-foreground" />
        <button
          class="inline-flex h-10 w-full items-center justify-center gap-2 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700"
          :class="[withdrawalNeeded ? ringClass : '']"
          @click="emit('withdraw')"
        >
          <IconArrowDown class="size-4" />
          {{ t('cashBook.recordWithdrawal') }}
        </button>
        <IconArrowDown class="size-5 text-muted-foreground" />
      </div>

      <CashBookStationInBox :current-balance="currentBalance" :last-entry-at="lastEntryAt" />

      <!-- Mobile arrow + button between station 2 and 3 -->
      <div class="flex flex-col items-center gap-2 sm:hidden">
        <IconArrowDown class="size-5 text-muted-foreground" />
        <button
          class="inline-flex h-10 w-full items-center justify-center gap-2 rounded-md border border-input bg-background px-4 text-sm font-medium hover:bg-accent"
          :class="[depositNeeded ? ringClass : '']"
          @click="emit('deposit')"
        >
          <IconBuildingBank class="size-4" />
          {{ t('cashBook.recordPayout') }}
        </button>
        <IconArrowDown class="size-5 text-muted-foreground" />
      </div>

      <CashBookStationLastBankDeposit :last-bank-deposit="lastBankDeposit" />
    </div>

    <!-- Desktop arrows + buttons row -->
    <div class="hidden sm:grid sm:grid-cols-3 sm:gap-4">
      <!-- Under arrow 1 -->
      <div class="flex justify-center">
        <button
          class="inline-flex h-10 items-center gap-2 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700"
          :class="[withdrawalNeeded ? ringClass : '']"
          @click="emit('withdraw')"
        >
          <IconArrowDown class="size-4" />
          {{ t('cashBook.recordWithdrawal') }}
        </button>
      </div>
      <!-- Under arrow 2 -->
      <div class="flex justify-center">
        <button
          class="inline-flex h-10 items-center gap-2 rounded-md border border-input bg-background px-4 text-sm font-medium hover:bg-accent"
          :class="[depositNeeded ? ringClass : '']"
          @click="emit('deposit')"
        >
          <IconBuildingBank class="size-4" />
          {{ t('cashBook.recordPayout') }}
        </button>
      </div>
      <!-- Spacer to align grid; nothing leaves station 3 -->
      <div></div>
    </div>

    <!-- Optional: small chevrons between station cards on desktop, purely visual.
         Implemented as a row of arrow icons positioned absolutely between the
         grid columns. Skipped here for simplicity — the side-by-side card
         layout already conveys the flow. Add later if visual polish demands. -->
  </div>
</template>
```

> **Note on the desktop chevrons:** The spec mockup shows `─▶` arrows between cards. The simple grid above does not render those; the visual hierarchy (3 cards in a row + 2 buttons centered below the first two) already communicates the flow clearly. If you want explicit chevrons, add a CSS pseudo-element in a follow-up — out of scope for this task.

- [ ] **Step 13.2: Commit**

```bash
git add management-frontend/app/components/cash-book/FlowVisualisation.vue
git commit -m "feat(cash-book): add FlowVisualisation composing the three stations and CTAs"
```

---

## Chunk 5: Secondary toolbar + EntriesTable

### Task 14: Build `SecondaryToolbar`

**Files:**
- Create: `management-frontend/app/components/cash-book/SecondaryToolbar.vue`

- [ ] **Step 14.1: Create the component**

```vue
<script setup lang="ts">
import { IconArrowsExchange, IconDevices, IconDownload, IconDots, IconSettings, IconTrash } from '@tabler/icons-vue'

const emit = defineEmits<{
  (e: 'correction'): void
  (e: 'manageMachines'): void
  (e: 'exportPdf'): void
  (e: 'openSettings'): void
  (e: 'delete'): void
}>()

const { t } = useI18n()
const moreOpen = ref(false)
const moreRef = ref<HTMLElement | null>(null)

onClickOutside(moreRef, () => { moreOpen.value = false })
</script>

<template>
  <div class="flex flex-wrap items-center gap-2">
    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('correction')"
    >
      <IconArrowsExchange class="size-4" />
      {{ t('cashBook.recordCorrection') }}
    </button>

    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('manageMachines')"
    >
      <IconDevices class="size-4" />
      {{ t('cashBook.assignMachines') }}
    </button>

    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('exportPdf')"
    >
      <IconDownload class="size-4" />
      {{ t('cashBook.exportPdf') }}
    </button>

    <div class="relative" ref="moreRef">
      <button
        class="inline-flex h-9 items-center gap-1 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
        @click="moreOpen = !moreOpen"
      >
        <IconDots class="size-4" />
        {{ t('cashBook.more') }}
      </button>
      <div
        v-if="moreOpen"
        class="absolute right-0 top-full mt-1 z-10 w-56 rounded-md border bg-popover shadow-md"
      >
        <button
          class="flex w-full items-center gap-2 px-3 py-2 text-sm hover:bg-accent"
          @click="moreOpen = false; emit('openSettings')"
        >
          <IconSettings class="size-4" />
          {{ t('cashBook.settings') }}
        </button>
        <button
          class="flex w-full items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-900/20"
          @click="moreOpen = false; emit('delete')"
        >
          <IconTrash class="size-4" />
          {{ t('cashBook.deleteCashBook') }}
        </button>
      </div>
    </div>
  </div>
</template>
```

> `onClickOutside` is from `@vueuse/core` — auto-imported by Nuxt.

- [ ] **Step 14.2: Commit**

```bash
git add management-frontend/app/components/cash-book/SecondaryToolbar.vue
git commit -m "feat(cash-book): add SecondaryToolbar with ⋯ Mehr menu"
```

### Task 15: Build `EntriesTable`

**Files:**
- Create: `management-frontend/app/components/cash-book/EntriesTable.vue`

- [ ] **Step 15.1: Create the component**

Move the entire entries-section (`<!-- Entries section -->` block at ~lines 643–757) into a new SFC. Props: `{ entries: CashBookEntry[]; loading: boolean; dateFilter: '30' | '90' | 'year' | 'all'; integrityResult: { verified: number; total: number; valid: boolean } | null; totalWithdrawals: { amount: number; count: number }; totalCorrections: { amount: number; count: number } }`. Emits `update:dateFilter` and `reverse(entry: CashBookEntry)`.

The component renders the inline stats strip above the date filter:

```vue
<div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between border-t px-4 py-2 text-xs text-muted-foreground">
  <div class="flex flex-wrap gap-x-4 gap-y-1">
    <span>{{ t('cashBook.totalWithdrawals') }}: {{ formatCurrency(totalWithdrawals.amount) }}</span>
    <span>·</span>
    <span>{{ t('cashBook.totalCorrections') }}: {{ totalCorrections.count }}</span>
    <span>·</span>
    <span v-if="integrityResult">{{ integrityResult.verified }}/{{ integrityResult.total }} {{ t('cashBook.entriesVerified') }}</span>
  </div>
</div>
```

The rest of the table (header, body, difference rows) is moved verbatim.

- [ ] **Step 15.2: Verify**

Hot-reload happens — the page is still using its inline version. Don't wire it in yet; that's Task 16.

- [ ] **Step 15.3: Commit**

```bash
git add management-frontend/app/components/cash-book/EntriesTable.vue
git commit -m "feat(cash-book): add EntriesTable with inline stats strip"
```

---

## Chunk 6: Page rewrite + smoke test

### Task 16: Rewrite `pages/cash-book/index.vue`

**Files:**
- Modify: `management-frontend/app/pages/cash-book/index.vue` (~1,110 → ~250 lines)

- [ ] **Step 16.1: Replace the page template**

The new template structure:

```vue
<template>
  <div class="flex flex-col gap-6 px-4 py-6 lg:px-6">
    <!-- Header (largely unchanged) -->
    <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
      <h1 class="text-2xl font-bold">{{ t('cashBook.title') }}</h1>
      <div class="flex items-center gap-3">
        <select v-if="cashBooks.length > 0" ...>...</select>
        <button @click="showCreateModal = true">...{{ t('cashBook.newCashBook') }}</button>
      </div>
    </div>

    <!-- Empty state (unchanged) -->
    <div v-if="cashBooks.length === 0 && !loading">...</div>

    <template v-if="selectedCashBook">
      <!-- NEW: flow visualisation -->
      <CashBookFlowVisualisation
        :theoretical-cash="theoreticalCash"
        :current-balance="currentBalance"
        :last-entry-at="theoreticalCash?.last_entry_at ?? null"
        :last-bank-deposit="lastBankDeposit"
        :bank-deposit-threshold="selectedCashBook.bank_deposit_threshold ?? 500"
        @withdraw="openWithdrawal"
        @deposit="showPayoutModal = true"
      />

      <!-- Error message (unchanged) -->
      <div v-if="errorMessage" ...>...</div>

      <!-- NEW: secondary toolbar -->
      <CashBookSecondaryToolbar
        @correction="showCorrectionModal = true"
        @manage-machines="openAssignModal"
        @export-pdf="exportPdf"
        @open-settings="showSettingsModal = true"
        @delete="openDeleteModal"
      />

      <!-- NEW: entries table component -->
      <CashBookEntriesTable
        :entries="entries"
        :loading="entriesLoading"
        :date-filter="dateFilter"
        :integrity-result="integrityResult"
        :total-withdrawals="totalWithdrawals"
        :total-corrections="totalCorrections"
        @update:date-filter="dateFilter = $event"
        @reverse="openReversalConfirm"
      />

      <!-- GoBD compliance footer (unchanged) -->
      <div class="rounded-xl border bg-card p-4">...</div>
    </template>

    <!-- All seven modals -->
    <CashBookCreateBarkasseModal v-model:open="showCreateModal" @submit="onCreateBarkasse" />
    <CashBookWithdrawalModal v-model:open="showWithdrawalModal" :theoretical-cash="theoreticalCash" :assigned-machines="assignedMachines" @submit="onWithdrawalSubmit" />
    <CashBookBankDepositModal v-model:open="showPayoutModal" :current-balance="currentBalance" @submit="onBankDepositSubmit" />
    <CashBookCorrectionModal v-model:open="showCorrectionModal" @submit="onCorrectionSubmit" />
    <CashBookReversalModal v-model:open="showReversalConfirm" :entry="reversalTarget" @confirm="submitReversal" />
    <CashBookAssignMachinesModal v-model:open="showAssignModal" :loading="assignLoading" :all-machines="allMachines" :selected-cash-book-id="selectedCashBook?.id ?? ''" :cash-books="cashBooks" @toggle="onMachineToggle" />
    <CashBookBarkasseSettingsModal v-model:open="showSettingsModal" :initial-threshold="selectedCashBook?.bank_deposit_threshold ?? 500" @submit="onSettingsSubmit" />
    <CashBookDeleteBarkasseModal v-model:open="showDeleteModal" :cash-book-name="selectedCashBook?.name ?? ''" :entry-count="integrityResult?.total ?? entries.length" :loading="deleting" @confirm="confirmDelete" />
  </div>
</template>
```

The four old KPI cards, the old theoretical-cash banner, and the row of five buttons are **removed**.

- [ ] **Step 16.2: Trim the script block**

Delete from the script:
- All form refs (`createForm`, `withdrawalForm`, `correctionForm`, `payoutForm`, `deleteConfirmName`, `deleteStep`)
- All loading flags except those still needed (`assignLoading`, `deleting`)
- All `submit*` functions (already replaced with `on*Submit` handlers)
- `getCashBookName` (only used by the assign modal — move into that component)
- `assignedMachines` computed (move into Withdrawal modal — already accepts `assignedMachines` prop, but the page still derives it from `allMachines`. Keep the page-side derivation for now; it's 4 lines.)

Add:
- `showSettingsModal = ref(false)` and the matching handler:
  ```ts
  async function onSettingsSubmit(threshold: number) {
    if (!selectedCashBook.value) return
    try {
      await updateBankDepositThreshold(selectedCashBook.value.id, threshold)
      showSettingsModal.value = false
    } catch (err: any) {
      errorMessage.value = err.message
    }
  }
  ```

The script block should now be ~150 lines instead of ~460.

- [ ] **Step 16.3: Type-check**

```bash
cd management-frontend
npx nuxi typecheck
```

Expected: zero errors. Fix anything reported.

- [ ] **Step 16.4: Commit**

```bash
git add management-frontend/app/pages/cash-book/index.vue
git commit -m "refactor(cash-book): rewrite page as composition of new components"
```

### Task 17: PDF export label sanity-check

**Files:** none (existing `exportPdf` function in the page should be unchanged)

- [ ] **Step 17.1: Verify PDF picks up the new labels**

In the page, click "PDF exportieren" (now in the secondary toolbar). Open the downloaded PDF. Confirm:
- The summary line reads "Aus Automaten gesamt: ..." (was "Bargeldeinnahmen")
- The entry-type column shows "Aus Automat", "Bankeinzahlung", "Korrektur", "Storno", "Anfangsbestand"
- The hash + GoBD footer + activation date are unchanged

If anything is off, the `typeLabel()` helper in the page needs updating to use the new i18n keys (it should already, since the keys' values changed in Chunk 2).

- [ ] **Step 17.2: Commit if any tweaks were needed**

```bash
git add management-frontend/app/pages/cash-book/index.vue
git commit -m "fix(cash-book): align PDF export labels with new i18n strings"
```

(Skip the commit if no changes were necessary.)

### Task 18: End-to-end smoke test

- [ ] **Step 18.1: Walk the full flow as a user would**

Reload `/cash-book` with a clean browser cache (Cmd+Shift+R / Ctrl+Shift+R).

Sequence:
1. Empty state: temporarily delete all Barkassen via the Studio (or use a brand-new test company). The empty state must show the icon + create button.
2. Create a Barkasse "End-to-End-Test" with initial 0 € and threshold 50 € (low so we can hit it easily).
3. Assign one machine via the secondary toolbar's "Automaten zuweisen". Check at least one machine.
4. Generate a cash sale. The cleanest way: open `/machines/<id>` and use the "Manueller Verkauf" form (calls `insert_manual_sale` RPC), which bypasses the `stamp_machine_and_decrement_stock` trigger constraints. Use `item_price = 75`, `channel = 'cash'`. As a fallback, you can insert directly into `sales` via Studio with `item_number` matching an existing tray on the assigned machine — a raw insert without a matching tray may fire the trigger and fail. The "In Automaten" station should refresh on next page reload to show 75 €. The "Aus Automat entnehmen" button must show the amber pulse ring.
5. Click "Geld aus Automat entnehmen". Modal shows "Erwartet aus Automaten: 75 €". Enter 75 €, submit. Entry table gains an "Aus Automat" row. The "In Automaten" station resets to 0 €. The "In der Kasse" station rises to 75 €.
6. Threshold is 50 €, balance is 75 €. The "Auf Bank einzahlen" button should now show the amber pulse ring.
7. Click "Geld auf Bank einzahlen". Modal shows current balance 75 €. Click "Gesamten Bestand" — amount fills with 75. Submit. New "Bankeinzahlung" row in the table. Station 2 drops to 0, station 3 shows 75 € today.
8. Open the ⋯ Mehr menu → "Einstellungen". Modal shows threshold 50. Change to 200, save. Reopen the modal — confirms 200. Confirm via Studio that the row's `bank_deposit_threshold` is now 200.
9. Open ⋯ Mehr → "Barkasse löschen". Step 1: cancel. Step 2: type a wrong name and confirm "Endgültig löschen" stays disabled. Type the correct name → button enables → click. Barkasse disappears from the dropdown.
10. Toggle the language switcher to English. Reload. All labels switch — "Take cash from machine", "Deposit to bank", "From machine", etc. Switch back to German.
11. Open the page on a mobile-sized viewport (Chrome devtools, iPhone SE 375 × 667). Stations stack vertically with downward arrows. The bottom tab bar is visible; the third station card is reachable by scrolling. Both action buttons remain tappable.

If any of these fail, fix in place and re-run the affected step. Do not move on with regressions.

- [ ] **Step 18.2: Final commit (if anything was tweaked)**

```bash
git add -A
git commit -m "chore(cash-book): smoke-test fixes"
```

(Skip if nothing changed.)

---

## Wrap-up

- [ ] **Step W.1: Confirm the page is now ~250 lines**

```bash
wc -l management-frontend/app/pages/cash-book/index.vue
```

Expected: `~250 management-frontend/app/pages/cash-book/index.vue`. If significantly more, extract any inline logic that should have moved into a component.

- [ ] **Step W.2: Confirm no broken i18n keys**

In the dev browser console, search for `[missing translation`. There should be zero hits while clicking through every button, modal, and menu.

- [ ] **Step W.3: Confirm no orphan files**

```bash
ls management-frontend/app/components/cash-book/
```

Expected: 13 files (3 stations + flow + 7 modals + secondary toolbar + entries table). No `*.vue.bak`, no `Old*`, no leftovers.

- [ ] **Step W.4: Push and open PR (when ready)**

This plan does not push automatically — open a PR when the user is ready to merge. The PR description should reference [docs/superpowers/specs/2026-05-07-kassenbuch-flow-redesign-design.md](../specs/2026-05-07-kassenbuch-flow-redesign-design.md) and link to a screenshot of the new flow.

---

## Skills Reference

- @superpowers:subagent-driven-development — preferred execution mode (one fresh subagent per task)
- @superpowers:executing-plans — fallback execution mode if subagents are unavailable
- @superpowers:verification-before-completion — before marking the plan done

## Out-of-Scope (do NOT add in this plan)

- Multi-machine collection wizard
- Realtime updates of station 1 via Supabase channels
- Bank-statement reconciliation
- Renaming `cash_book_entries.type` enum values (would break the GoBD hash chain)
- iOS app changes
