# Kassenbuch Barausgaben Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Barentnahmen aus der Barkasse für betriebliche Zwecke (Miete, Wareneinkauf, Reinigung, Gebühren, Sonstiges) als eigene, GoBD-konforme Buchungsart `expense` mit Pflicht-Belegverweis erfassen – im Backend, in der PWA und in der nativen iOS-App.

**Architecture:** Neue, idempotente DB-Migration erweitert die `valid_type`-CHECK um `expense`, fügt `category` + `receipt_reference` (nullable) hinzu und erzwingt per CHECK Kategorie+Beleg bei Ausgaben. Ausgaben werden als reguläre Einträge mit negativem `amount` gebucht (bestehender Trigger senkt `balance_after` automatisch). Frontend (PWA + iOS) bekommt je ein Erfassungs-Formular, einen Toolbar-Button und die Anzeige in Tabelle/Liste/PDF. Hash-Kette und `get_theoretical_cash` bleiben unverändert.

**Tech Stack:** PostgreSQL (Supabase migrations), Nuxt 4 + TypeScript + Vue 3 + vitest, SwiftUI + Supabase-Swift.

**Spec:** `docs/superpowers/specs/2026-06-29-cash-book-expenses-design.md`

**Branch note:** Arbeite direkt auf dem aktuellen Branch (`main`), KEIN Worktree (User-Präferenz). Migrationen sind immutable – nur NEUE Datei anlegen, bestehende nie editieren. NIE `supabase db reset` ausführen; nur `supabase migration up`.

---

## File Structure

**Backend (DB)**
- Create: `Docker/supabase/migrations/20260629120000_cash_book_expense.sql` — CHECK erweitern, neue Spalten, GoBD-CHECK.

**PWA**
- Modify: `management-frontend/app/composables/useCashBook.ts` — Typ-Union, `createEntry`-Felder, `totalExpenses`, Kategorie-Konstante.
- Create: `management-frontend/app/components/cash-book/ExpenseModal.vue` — Erfassungsformular.
- Modify: `management-frontend/app/components/cash-book/SecondaryToolbar.vue` — Button „Barausgabe".
- Modify: `management-frontend/app/pages/cash-book/index.vue` — Modal + Handler + PDF-Spalten.
- Modify: `management-frontend/app/components/cash-book/EntriesTable.vue` — Badge/Label + Kategorie/Beleg-Subzeile.
- Modify: `management-frontend/app/components/cash-book/ReversalModal.vue` — `expense`-Label.
- Modify: `management-frontend/i18n/locales/de.json`, `management-frontend/i18n/locales/en.json` — neue Strings.
- Create: `management-frontend/app/composables/__tests__/useCashBook.expense.test.ts` — vitest für Vorzeichen + totalExpenses.

**iOS**
- Modify: `ios/VMflow/Models/CashBook.swift` — `.expense` + `.unknown`-Fallback, optionale Felder.
- Modify: `ios/VMflow/ViewModels/CashBookViewModel.swift` — `recordExpense()` + `expenseCategories`.
- Create: `ios/VMflow/Views/CashBook/ExpenseSheet.swift` — Erfassungs-Sheet.
- Modify: `ios/VMflow/Views/CashBook/CashBookView.swift` — Button + Sheet-Verdrahtung.
- Modify: `ios/VMflow/Views/CashBook/EntriesListSection.swift` — `switch`-Fälle + Kategorie/Beleg-Subzeile.
- Modify: `ios/VMflow/Resources/Localizable.xcstrings` — deutsche Strings.
- Modify: `ios/VMflow.xcodeproj/project.pbxproj` — `ExpenseSheet.swift` an 4 Stellen registrieren.

---

## Chunk 1: Datenbank-Migration

### Task 1.1: Migration anlegen

**Files:**
- Create: `Docker/supabase/migrations/20260629120000_cash_book_expense.sql`

- [ ] **Step 1: Migration schreiben**

> Falls bereits eine Migration mit Timestamp ≥ `20260629120000` existiert, wähle einen höheren Timestamp, der nach ALLEN bestehenden Migrationen liegt. Alle Statements sind idempotent.

```sql
-- Barausgaben (cash expenses) für das Kassenbuch.
-- Neue Buchungsart 'expense': Geld verlässt die Barkasse für einen
-- betrieblichen Zweck (Miete, Wareneinkauf, ...). amount ist NEGATIV;
-- der bestehende before_insert-Trigger senkt balance_after automatisch.
-- Idempotent: kann auf bestehenden Installationen via update.sh laufen.

-- 1. 'expense' zur Buchungsart-Whitelist hinzufügen.
ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS valid_type;
ALTER TABLE public.cash_book_entries ADD CONSTRAINT valid_type
  CHECK (type IN ('initial','withdrawal','correction','payout','expense','reversal'));

-- 2. Kategorie + Belegverweis (nullable; Altzeilen bleiben unberührt).
ALTER TABLE public.cash_book_entries ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE public.cash_book_entries ADD COLUMN IF NOT EXISTS receipt_reference text;

-- 3. GoBD: Ausgaben MÜSSEN Kategorie + Beleg haben (Defense-in-Depth gegen
--    rohe PostgREST-Inserts / künftige Schreib-Clients). No-op für alle
--    Nicht-Ausgaben, da Altzeilen type <> 'expense' sind.
ALTER TABLE public.cash_book_entries DROP CONSTRAINT IF EXISTS expense_requires_category_receipt;
ALTER TABLE public.cash_book_entries ADD CONSTRAINT expense_requires_category_receipt
  CHECK (type <> 'expense'
         OR (category IS NOT NULL AND receipt_reference IS NOT NULL));
```

- [ ] **Step 2: Migration anwenden**

Run: `cd Docker/supabase && supabase migration up`
Expected: Migration `20260629120000_cash_book_expense` wird angewandt, keine Fehler. (NICHT `db reset`.)

- [ ] **Step 3: CHECK-Verhalten verifizieren (manuell, lokale Dev-DB)**

Ziel: eine gültige Ausgabe wird akzeptiert, eine Ausgabe ohne Kategorie/Beleg wird abgelehnt, `balance_after` sinkt. Nutze eine bestehende Barkasse-ID aus der Dev-DB.

Run (lokale Supabase-DB, Port 54322 – ersetze `<CASH_BOOK_ID>` und `<COMPANY_ID>` mit echten Werten aus `select id, company_id from cash_books limit 1;`):
```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" <<'SQL'
BEGIN;
-- gültige Ausgabe: muss durchgehen, balance_after < vorheriger Bestand
INSERT INTO cash_book_entries (cash_book_id, company_id, type, amount, category, receipt_reference, description, created_by)
VALUES ('<CASH_BOOK_ID>','<COMPANY_ID>','expense', -100.00, 'rent', 'RE-2026-001', 'Miete Juni', (SELECT created_by FROM cash_books WHERE id='<CASH_BOOK_ID>'))
RETURNING entry_number, type, amount, balance_after, category, receipt_reference;
-- ungültige Ausgabe: muss mit CHECK-Verletzung scheitern
INSERT INTO cash_book_entries (cash_book_id, company_id, type, amount, description, created_by)
VALUES ('<CASH_BOOK_ID>','<COMPANY_ID>','expense', -50.00, 'kein Beleg', (SELECT created_by FROM cash_books WHERE id='<CASH_BOOK_ID>'));
ROLLBACK;
SQL
```
Expected: Erster INSERT liefert eine Zeile mit `type=expense`, negativem `amount`, gesunkenem `balance_after`. Zweiter INSERT bricht ab mit `new row ... violates check constraint "expense_requires_category_receipt"`. `ROLLBACK` verwirft beides (keine Testdaten bleiben zurück).

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/migrations/20260629120000_cash_book_expense.sql
git commit -m "feat(cash-book): add expense entry type with category + receipt (DB)" -- Docker/supabase/migrations/20260629120000_cash_book_expense.sql
```

---

## Chunk 2: PWA

### Task 2.1: Composable erweitern (Typen, createEntry, totalExpenses, Kategorien)

**Files:**
- Modify: `management-frontend/app/composables/useCashBook.ts`

- [ ] **Step 1: `CashBookEntry`-Typ-Union + neue Felder erweitern**

In `interface CashBookEntry` (ca. Zeile 27) die `type`-Union um `expense` erweitern und zwei optionale Felder ergänzen:

```ts
  type: 'initial' | 'withdrawal' | 'correction' | 'payout' | 'expense' | 'reversal'
  amount: number
  balance_after: number
  description: string | null
  machine_id: string | null
  counted_amount: number | null
  expected_amount: number | null
  category: string | null
  receipt_reference: string | null
  corrects_entry_id: string | null
```

- [ ] **Step 2: Kategorie-Konstante exportieren**

Direkt unter den Interfaces (vor `const userCache`) einfügen:

```ts
// ── Expense categories (fixed list; labels via i18n) ─────────────────────────

export const EXPENSE_CATEGORIES = ['rent', 'goods', 'cleaning', 'fees', 'other'] as const
export type ExpenseCategory = typeof EXPENSE_CATEGORIES[number]
```

- [ ] **Step 3: `createEntry` um `expense` + Felder erweitern**

Den Parameter-Typ von `createEntry` (ca. Zeile 247) erweitern:

```ts
  async function createEntry(entry: {
    cash_book_id: string
    type: 'withdrawal' | 'correction' | 'payout' | 'expense' | 'reversal'
    amount: number
    description?: string
    machine_id?: string | null
    counted_amount?: number | null
    expected_amount?: number | null
    category?: string | null
    receipt_reference?: string | null
    corrects_entry_id?: string | null
  }) {
```

Die `insert(...)` selbst bleibt unverändert (`...entry` übernimmt die neuen Felder automatisch). Die `logActivity`-Metadaten optional um `category` ergänzen:

```ts
    await logActivity('cash_book_entry_created', data.id, {
      cash_book_id: entry.cash_book_id,
      type: entry.type,
      amount: entry.amount,
      description: entry.description,
      category: entry.category ?? null,
    })
```

> Designentscheidung: Wir erweitern `createEntry` statt eine separate `createExpense()` zu bauen. Das spiegelt das bestehende Muster (die Page ruft `createEntry` für withdrawal/payout/correction direkt auf) und bleibt DRY. Die Spec nennt `createExpense()` nur als Beispielnamen.

- [ ] **Step 4: `totalExpenses`-Computed ergänzen**

Nach `totalCorrections` (ca. Zeile 423) einfügen:

```ts
  const totalExpenses = computed(() => {
    const expenses = entries.value.filter(e => e.type === 'expense' && !e.is_reversed)
    return {
      amount: expenses.reduce((sum, e) => sum + Math.abs(e.amount), 0),
      count: expenses.length,
    }
  })
```

Und im `return { ... }`-Block bei den Computed KPIs `totalExpenses` ergänzen (neben `totalWithdrawals`, `totalCorrections`).

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useCashBook.ts
git commit -m "feat(cash-book): expense type, category constant, totalExpenses (composable)" -- management-frontend/app/composables/useCashBook.ts
```

### Task 2.2: Vitest für Vorzeichen + totalExpenses

**Files:**
- Create: `management-frontend/app/composables/__tests__/useCashBook.expense.test.ts`

> Hinweis: `useCashBook` zieht viele Nuxt-Autoimports (`useSupabaseClient`, `useOrganization`, `computed`, `ref`). Ein voller Composable-Mount ist im Test-Setup aufwändig. Teste daher die **reine Logik** isoliert: die Vorzeichen-Konvention der Ausgabe (`amount = -abs(input)`) und die `totalExpenses`-Aggregation als eigenständige, hier nachgebaute Pure-Funktionen, die exakt der Composable-Logik entsprechen. Prüfe zusätzlich, dass `EXPENSE_CATEGORIES` den vereinbarten Satz enthält (echter Import).

- [ ] **Step 1: Failing test schreiben**

```ts
import { describe, it, expect } from 'vitest'
import { EXPENSE_CATEGORIES } from '@/composables/useCashBook'

// Spiegelt die Composable-Logik: Ausgabe wird mit negativem amount gebucht.
function expenseAmount(input: number): number {
  return -Math.abs(input)
}

// Spiegelt totalExpenses: Summe der Beträge nicht-stornierter Ausgaben.
function totalExpenses(entries: { type: string; amount: number; is_reversed: boolean }[]) {
  const ex = entries.filter(e => e.type === 'expense' && !e.is_reversed)
  return { amount: ex.reduce((s, e) => s + Math.abs(e.amount), 0), count: ex.length }
}

describe('cash book expenses', () => {
  it('books expenses with a negative amount', () => {
    expect(expenseAmount(100)).toBe(-100)
    expect(expenseAmount(-100)).toBe(-100)
  })

  it('aggregates totalExpenses over non-reversed expense entries', () => {
    const entries = [
      { type: 'expense', amount: -100, is_reversed: false },
      { type: 'expense', amount: -50, is_reversed: true },  // storniert → ignoriert
      { type: 'payout', amount: -200, is_reversed: false }, // andere Art → ignoriert
      { type: 'expense', amount: -25, is_reversed: false },
    ]
    expect(totalExpenses(entries)).toEqual({ amount: 125, count: 2 })
  })

  it('exposes the fixed category list', () => {
    expect([...EXPENSE_CATEGORIES]).toEqual(['rent', 'goods', 'cleaning', 'fees', 'other'])
  })
})
```

- [ ] **Step 2: Test laufen lassen (muss zuerst grün/rot sauber sein)**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useCashBook.expense.test.ts`
Expected: PASS (3 Tests). Falls der Import von `EXPENSE_CATEGORIES` fehlschlägt → Task 2.1 Step 2 nachziehen.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/composables/__tests__/useCashBook.expense.test.ts
git commit -m "test(cash-book): expense sign + totalExpenses + category list" -- management-frontend/app/composables/__tests__/useCashBook.expense.test.ts
```

### Task 2.3: ExpenseModal.vue

**Files:**
- Create: `management-frontend/app/components/cash-book/ExpenseModal.vue`

- [ ] **Step 1: Komponente schreiben** (orientiert an `WithdrawalModal.vue`)

```vue
<script setup lang="ts">
import { EXPENSE_CATEGORIES } from '@/composables/useCashBook'

defineProps<{
  open: boolean
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'submit', payload: { amount: number; category: string; receiptReference: string; description: string }): void
}>()

const { t } = useI18n()

const form = ref({
  amount: 0,
  category: 'rent' as string,
  receipt_reference: '',
  description: '',
})
const loading = ref(false)

const needsDescription = computed(() => form.value.category === 'other')
const canSubmit = computed(() =>
  form.value.amount > 0
  && form.value.receipt_reference.trim().length > 0
  && (!needsDescription.value || form.value.description.trim().length > 0),
)

function categoryLabel(code: string): string {
  return t(`cashBook.category_${code}`)
}

watch(() => props.open, (now) => {
  if (now) {
    form.value = { amount: 0, category: 'rent', receipt_reference: '', description: '' }
  }
})

const props = defineProps<{ open: boolean }>()

async function onSubmit() {
  if (!canSubmit.value) return
  loading.value = true
  try {
    emit('submit', {
      amount: form.value.amount,
      category: form.value.category,
      receiptReference: form.value.receipt_reference.trim(),
      description: form.value.description.trim(),
    })
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <AppModal
    :open="open"
    :title="t('cashBook.recordExpense')"
    size="sm"
    @update:open="(v: boolean) => emit('update:open', v)"
  >
    <form class="space-y-4" @submit.prevent="onSubmit">
      <div>
        <label class="text-sm font-medium">{{ t('cashBook.amount') }} (EUR)</label>
        <input
          v-model.number="form.amount"
          type="number" step="0.01" min="0" required
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.category') }}</label>
        <select
          v-model="form.category"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option v-for="c in EXPENSE_CATEGORIES" :key="c" :value="c">
            {{ categoryLabel(c) }}
          </option>
        </select>
      </div>

      <div>
        <label class="text-sm font-medium">{{ t('cashBook.receiptReference') }}</label>
        <input
          v-model="form.receipt_reference"
          type="text" required
          :placeholder="t('cashBook.receiptReferencePlaceholder')"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div>
        <label class="text-sm font-medium">
          {{ t('cashBook.description') }}
          <span v-if="needsDescription" class="text-red-600">*</span>
        </label>
        <input
          v-model="form.description"
          type="text"
          :required="needsDescription"
          class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>

      <div class="flex justify-end gap-2">
        <button type="button" class="h-9 rounded-md border border-input px-4 text-sm font-medium hover:bg-accent" @click="emit('update:open', false)">
          {{ t('common.cancel') }}
        </button>
        <button type="submit" :disabled="loading || !canSubmit"
                class="h-9 rounded-md bg-amber-600 px-4 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50">
          {{ loading ? t('common.loading') : t('cashBook.bookEntry') }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
```

> Achtung Reihenfolge: `props` muss vor dem `watch(() => props.open, …)` definiert sein. Stelle die `const props = defineProps<{ open: boolean }>()`-Zeile beim Implementieren NACH OBEN (direkt unter `<script setup>`), und entferne das doppelte `defineProps` oben im Snippet – im finalen File darf `defineProps` nur EINMAL vorkommen. (Das obige Snippet zeigt beide Stellen nur zur Verdeutlichung; nutze ein einziges `const props = defineProps<{ open: boolean }>()` ganz oben, analog `WithdrawalModal.vue` das `props` ebenfalls oben hält.)

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/components/cash-book/ExpenseModal.vue
git commit -m "feat(cash-book): ExpenseModal for recording cash expenses (PWA)" -- management-frontend/app/components/cash-book/ExpenseModal.vue
```

### Task 2.4: Toolbar-Button

**Files:**
- Modify: `management-frontend/app/components/cash-book/SecondaryToolbar.vue`

- [ ] **Step 1: Emit + Button ergänzen**

Im `defineEmits` einen `expense`-Event ergänzen:

```ts
const emit = defineEmits<{
  (e: 'expense'): void
  (e: 'correction'): void
  (e: 'manageMachines'): void
  (e: 'exportPdf'): void
  (e: 'openSettings'): void
  (e: 'delete'): void
}>()
```

Import um ein Icon ergänzen (z.B. `IconReceipt`):

```ts
import { IconArrowsExchange, IconDevices, IconDownload, IconDots, IconReceipt, IconSettings, IconTrash } from '@tabler/icons-vue'
```

Als ersten Button im Template (vor „Korrektur erfassen") einfügen:

```vue
    <button
      class="inline-flex h-9 items-center gap-2 rounded-md border border-input bg-background px-3 text-sm font-medium hover:bg-accent"
      @click="emit('expense')"
    >
      <IconReceipt class="size-4" />
      {{ t('cashBook.recordExpense') }}
    </button>
```

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/components/cash-book/SecondaryToolbar.vue
git commit -m "feat(cash-book): expense button in secondary toolbar (PWA)" -- management-frontend/app/components/cash-book/SecondaryToolbar.vue
```

### Task 2.5: Page-Verdrahtung + PDF

**Files:**
- Modify: `management-frontend/app/pages/cash-book/index.vue`

- [ ] **Step 1: State + Handler ergänzen**

Bei den Modal-Flags (ca. Zeile 48) ergänzen:

```ts
const showExpenseModal = ref(false)
```

Bei den Computed-Destructure aus `useCashBook()` `totalExpenses` ergänzen (im großen `const { ... } = useCashBook()`-Block neben `totalCorrections`).

Neuen Handler nach `onCorrectionSubmit` (ca. Zeile 204) einfügen:

```ts
async function onExpenseSubmit(payload: { amount: number; category: string; receiptReference: string; description: string }) {
  if (!selectedCashBook.value) return
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'expense',
      amount: -Math.abs(payload.amount),
      description: payload.description || null,
      category: payload.category,
      receipt_reference: payload.receiptReference,
    })
    showExpenseModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  }
}
```

- [ ] **Step 2: typeLabel um `expense` ergänzen (für PDF)**

In `typeLabel(type)` (ca. Zeile 290) die Map um `expense` erweitern:

```ts
    payout: t('cashBook.typePayout'),
    expense: t('cashBook.typeExpense'),
    reversal: t('cashBook.typeReversal'),
```

- [ ] **Step 3: Toolbar + Modal im Template verdrahten**

Beim `<CashBookSecondaryToolbar ...>` (ca. Zeile 453) Handler ergänzen:

```vue
      <CashBookSecondaryToolbar
        @expense="showExpenseModal = true"
        @correction="showCorrectionModal = true"
        @manage-machines="openAssignModal"
        @export-pdf="exportPdf"
        @open-settings="showSettingsModal = true"
        @delete="showDeleteModal = true"
      />
```

Bei den Modals (nach `<CashBookCorrectionModal ...>`, ca. Zeile 516) einfügen:

```vue
    <CashBookExpenseModal
      v-model:open="showExpenseModal"
      @submit="onExpenseSubmit"
    />
```

- [ ] **Step 4: PDF-Export — Kategorie/Beleg in Ausgabe-Zeilen**

Im `autoTable`-`body`-Map (ca. Zeile 354) die Beschreibung für Ausgaben um Kategorie + Beleg anreichern:

```ts
    body: allEntries.map((e: any) => [
      e.entry_number,
      formatDateTime(e.created_at),
      typeLabel(e.type) + (e.is_reversed ? ` (${t('cashBook.reversed')})` : ''),
      formatAmount(e.amount),
      formatCurrency(e.balance_after),
      e.type === 'expense'
        ? [t(`cashBook.category_${e.category}`), e.receipt_reference, e.description].filter(Boolean).join(' · ')
        : (e.description || '—'),
    ]),
```

- [ ] **Step 5: Lint/Typecheck**

Run: `cd management-frontend && npx nuxi typecheck`
Expected: keine neuen Typfehler in `cash-book/index.vue`, `useCashBook.ts`, `ExpenseModal.vue`. (Falls `nuxi typecheck` projektweit bereits Vorfehler hat, prüfe gezielt, dass KEIN neuer Fehler in den geänderten Dateien auftaucht.)

- [ ] **Step 6: Commit**

```bash
git add management-frontend/app/pages/cash-book/index.vue
git commit -m "feat(cash-book): wire expense modal + PDF columns (PWA page)" -- management-frontend/app/pages/cash-book/index.vue
```

### Task 2.6: EntriesTable + ReversalModal

**Files:**
- Modify: `management-frontend/app/components/cash-book/EntriesTable.vue`
- Modify: `management-frontend/app/components/cash-book/ReversalModal.vue`

- [ ] **Step 1: EntriesTable Badge + Label um `expense`**

In `typeBadgeClass` (ca. Zeile 24) vor `default` einen `expense`-Fall ergänzen:

```ts
    case 'expense': return 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400 border-amber-200 dark:border-amber-800'
```

In `typeLabel` (ca. Zeile 35) die Map um `expense: t('cashBook.typeExpense')` ergänzen.

- [ ] **Step 2: EntriesTable — Kategorie/Beleg-Subzeile**

Nach der bestehenden Differenz-Subzeile (`<tr v-if="entry.counted_amount != null …">`, endet ca. Zeile 171) eine zweite Subzeile für Ausgaben ergänzen:

```vue
              <tr v-if="entry.type === 'expense' && (entry.category || entry.receipt_reference)">
                <td colspan="7" class="px-4 py-1.5 text-xs text-muted-foreground">
                  <span v-if="entry.category">{{ t(`cashBook.category_${entry.category}`) }}</span>
                  <span v-if="entry.receipt_reference"> · {{ t('cashBook.receiptReference') }}: {{ entry.receipt_reference }}</span>
                </td>
              </tr>
```

- [ ] **Step 3: ReversalModal — `expense`-Label**

In `typeLabel` (ca. Zeile 18) die Map um `expense: t('cashBook.typeExpense')` ergänzen (neben `payout`).

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/components/cash-book/EntriesTable.vue management-frontend/app/components/cash-book/ReversalModal.vue
git commit -m "feat(cash-book): show expense type/category/receipt in table + reversal label (PWA)" -- management-frontend/app/components/cash-book/EntriesTable.vue management-frontend/app/components/cash-book/ReversalModal.vue
```

### Task 2.7: i18n

**Files:**
- Modify: `management-frontend/i18n/locales/de.json`
- Modify: `management-frontend/i18n/locales/en.json`

- [ ] **Step 1: Neue Keys im `cashBook`-Block (de.json)**

Im bestehenden `"cashBook": { ... }`-Objekt ergänzen (Komma-Syntax beachten):

```json
    "recordExpense": "Barausgabe",
    "typeExpense": "Ausgabe",
    "category": "Kategorie",
    "receiptReference": "Belegnr.",
    "receiptReferencePlaceholder": "z. B. RE-2026-001",
    "totalExpenses": "Ausgaben gesamt",
    "category_rent": "Miete",
    "category_goods": "Wareneinkauf",
    "category_cleaning": "Reinigung",
    "category_fees": "Gebühren",
    "category_other": "Sonstiges",
```

- [ ] **Step 2: Gleiche Keys in en.json**

```json
    "recordExpense": "Cash expense",
    "typeExpense": "Expense",
    "category": "Category",
    "receiptReference": "Receipt no.",
    "receiptReferencePlaceholder": "e.g. INV-2026-001",
    "totalExpenses": "Total expenses",
    "category_rent": "Rent",
    "category_goods": "Goods purchase",
    "category_cleaning": "Cleaning",
    "category_fees": "Fees",
    "category_other": "Other",
```

- [ ] **Step 3: JSON valide?**

Run: `cd management-frontend && node -e "JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8')); JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8')); console.log('ok')"`
Expected: `ok`

- [ ] **Step 4: Vitest-Suite grün halten**

Run: `cd management-frontend && npx vitest run`
Expected: alle Tests PASS (inkl. neuem Expense-Test).

- [ ] **Step 5: Commit**

```bash
git add management-frontend/i18n/locales/de.json management-frontend/i18n/locales/en.json
git commit -m "feat(cash-book): i18n for expenses (de/en)" -- management-frontend/i18n/locales/de.json management-frontend/i18n/locales/en.json
```

---

## Chunk 3: iOS (VMflow)

### Task 3.1: Model — `.expense` + `.unknown`-Fallback + optionale Felder

**Files:**
- Modify: `ios/VMflow/Models/CashBook.swift`

- [ ] **Step 1: Enum erweitern + forward-kompatibler Decoder**

`CashBookEntryType` (ca. Zeile 29) ersetzen durch:

```swift
enum CashBookEntryType: String, Codable {
    case initial
    case withdrawal
    case correction
    case payout
    case expense
    case reversal
    /// Forward-compat: unknown raw values (e.g. a future server type) decode
    /// here instead of throwing and failing the whole entries list.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CashBookEntryType(rawValue: raw) ?? .unknown
    }
}
```

- [ ] **Step 2: Optionale Felder auf `CashBookEntry`**

In `struct CashBookEntry` (ca. Zeile 50, nach `expectedAmount`) ergänzen:

```swift
    let countedAmount: Double?
    let expectedAmount: Double?
    let category: String?
    let receiptReference: String?
    let correctsEntryId: UUID?
```

Und in `CodingKeys` (ca. Zeile 67) ergänzen:

```swift
        case countedAmount = "counted_amount"
        case expectedAmount = "expected_amount"
        case category
        case receiptReference = "receipt_reference"
        case correctsEntryId = "corrects_entry_id"
```

> Beide Felder MÜSSEN optional sein – Altzeilen liefern `null`; synthetisiertes `Codable` dekodiert `String?` via `decodeIfPresent` automatisch, sodass historische Buchungen weiter dekodieren.

- [ ] **Step 3: Decode-Verhalten verifizieren (throwaway swift)**

Run:
```bash
cat > /tmp/cbtype.swift <<'SWIFT'
import Foundation
enum CashBookEntryType: String, Codable {
    case initial, withdrawal, correction, payout, expense, reversal, unknown
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CashBookEntryType(rawValue: raw) ?? .unknown
    }
}
let dec = JSONDecoder()
let e = try dec.decode(CashBookEntryType.self, from: "\"expense\"".data(using: .utf8)!)
let u = try dec.decode(CashBookEntryType.self, from: "\"future_type\"".data(using: .utf8)!)
print(e, u)
assert(e == .expense); assert(u == .unknown)
print("ok")
SWIFT
swift /tmp/cbtype.swift
```
Expected: `expense unknown` dann `ok` (kein throw bei unbekanntem Wert).

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Models/CashBook.swift
git commit -m "feat(cash-book): expense type, unknown fallback, optional category/receipt (iOS model)" -- ios/VMflow/Models/CashBook.swift
```

### Task 3.2: ViewModel — `recordExpense()` + Kategorien

**Files:**
- Modify: `ios/VMflow/ViewModels/CashBookViewModel.swift`

- [ ] **Step 1: Kategorie-Liste als statische Property**

In der Klasse (nach den `@Published`-Properties, ca. Zeile 16) ergänzen:

```swift
    /// Fixed expense categories (codes). Labels live in Localizable.xcstrings
    /// as cash_book_category_<code>.
    let expenseCategories = ["rent", "goods", "cleaning", "fees", "other"]
```

- [ ] **Step 2: `recordExpense()` nach `recordBankDeposit()` (ca. Zeile 266) einfügen**

```swift
    /// Records a cash expense (money OUT of the box for a business purpose).
    /// Caller passes a non-negative `amount`; we negate internally so the
    /// running balance decreases. category + receiptReference are required by
    /// the DB CHECK (GoBD).
    func recordExpense(
        cashBookId: UUID,
        amount: Double,
        category: String,
        receiptReference: String,
        description: String
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              let userId = client.auth.currentUser?.id else {
            throw CashBookError.notAuthenticated
        }

        struct Insert: Encodable {
            let cash_book_id: UUID
            let company_id: UUID
            let type: String
            let amount: Double
            let category: String
            let receipt_reference: String
            let description: String?
            let created_by: UUID
        }

        let row = Insert(
            cash_book_id: cashBookId,
            company_id: companyId,
            type: "expense",
            amount: -abs(amount),                 // NEGATIVE — money OUT of the box
            category: category,
            receipt_reference: receiptReference,
            description: description.isEmpty ? nil : description,
            created_by: userId
        )

        try await client.from("cash_book_entries").insert(row).execute()

        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
    }
```

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/ViewModels/CashBookViewModel.swift
git commit -m "feat(cash-book): recordExpense + categories (iOS view model)" -- ios/VMflow/ViewModels/CashBookViewModel.swift
```

### Task 3.3: ExpenseSheet.swift

**Files:**
- Create: `ios/VMflow/Views/CashBook/ExpenseSheet.swift`

- [ ] **Step 1: Sheet schreiben** (vereinfachte Variante von `WithdrawalSheet`, ohne Theoretik/Maschine)

```swift
import SwiftUI

/// Records a cash expense (money OUT of the box for a business purpose).
/// Category + receipt reference are required (GoBD); description is required
/// only for the "other" category.
struct ExpenseSheet: View {
    let cashBook: CashBook

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    @State private var amountText: String = ""
    @State private var category: String = "rent"
    @State private var receiptReference: String = ""
    @State private var description: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var amount: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var needsDescription: Bool { category == "other" }

    private var canSubmit: Bool {
        amount > 0
        && !receiptReference.trimmingCharacters(in: .whitespaces).isEmpty
        && (!needsDescription || !description.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("cash_book_amount") {
                    TextField("0,00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                }

                Section("cash_book_category") {
                    Picker("cash_book_category", selection: $category) {
                        ForEach(cashBookVM.expenseCategories, id: \.self) { code in
                            Text(LocalizedStringKey("cash_book_category_\(code)")).tag(code)
                        }
                    }
                    .labelsHidden()
                }

                Section("cash_book_receipt_reference") {
                    TextField("cash_book_receipt_reference_placeholder", text: $receiptReference)
                }

                Section {
                    TextField(text: $description) { Text(verbatim: "") }
                } header: {
                    Text(needsDescription ? "cash_book_description_required" : "cash_book_description")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cash_book_cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("cash_book_book_entry") }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await cashBookVM.recordExpense(
                cashBookId: cashBook.id,
                amount: amount,
                category: category,
                receiptReference: receiptReference.trimmingCharacters(in: .whitespaces),
                description: description.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Commit** (Datei wird in Task 3.6 ins pbxproj registriert)

```bash
git add ios/VMflow/Views/CashBook/ExpenseSheet.swift
git commit -m "feat(cash-book): ExpenseSheet (iOS)" -- ios/VMflow/Views/CashBook/ExpenseSheet.swift
```

### Task 3.4: CashBookView — Button + Sheet

**Files:**
- Modify: `ios/VMflow/Views/CashBook/CashBookView.swift`

- [ ] **Step 1: State-Flag + Toolbar-Button + Sheet**

State ergänzen (ca. Zeile 6):

```swift
    @State private var showExpense = false
```

In `.toolbar` (nach dem Picker-Block, ca. Zeile 27) einen Plus-/Receipt-Button ergänzen, der die Ausgabe öffnet (nur wenn eine Barkasse gewählt ist):

```swift
            if cashBookVM.selectedCashBook != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showExpense = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .accessibilityLabel("cash_book_record_expense")
                }
            }
```

In `content(book:)` einen weiteren `.sheet` neben den bestehenden (ca. Zeile 71) ergänzen:

```swift
        .sheet(isPresented: $showExpense) {
            ExpenseSheet(cashBook: book)
                .environmentObject(cashBookVM)
        }
```

> Hinweis: `showExpense` ist auf View-Ebene definiert, der Button steht im `.toolbar` der `body`. Da der Button nur erscheint, wenn `selectedCashBook != nil`, und `content(book:)` genau dann gerendert wird, ist das Sheet korrekt an die `book`-Instanz gebunden. Falls die Toolbar-Bindung zickt, alternativ den Button in `content(book:)`-Scope verschieben (z. B. als Section-Header-Button) — Hauptsache er ist nur bei vorhandener Barkasse sichtbar.

- [ ] **Step 2: Commit**

```bash
git add ios/VMflow/Views/CashBook/CashBookView.swift
git commit -m "feat(cash-book): expense button + sheet wiring (iOS view)" -- ios/VMflow/Views/CashBook/CashBookView.swift
```

### Task 3.5: EntriesListSection — switch-Fälle + Subzeile

**Files:**
- Modify: `ios/VMflow/Views/CashBook/EntriesListSection.swift`

- [ ] **Step 1: `badgeStyle(for:)` um `.expense` + `.unknown` erweitern**

Der `switch` (ca. Zeile 81) ist erschöpfend ohne `default` → MUSS beide neuen Fälle behandeln, sonst Build-Fehler:

```swift
    private func badgeStyle(for type: CashBookEntryType) -> (LocalizedStringKey, Color) {
        switch type {
        case .initial:    return ("cash_book_type_initial",    .gray)
        case .withdrawal: return ("cash_book_type_withdrawal", .red)
        case .correction: return ("cash_book_type_correction", .yellow)
        case .payout:     return ("cash_book_type_payout",     .blue)
        case .expense:    return ("cash_book_type_expense",    .orange)
        case .reversal:   return ("cash_book_type_reversal",   .orange)
        case .unknown:    return ("cash_book_type_unknown",    .gray)
        }
    }
```

- [ ] **Step 2: Kategorie/Beleg-Subzeile im `row(for:)`**

Nach der Maschinen-Subzeile (ca. Zeile 63, vor dem schließenden `}` des `VStack`) ergänzen:

```swift
            // Optional subline: expense category + receipt
            if entry.type == .expense {
                HStack(spacing: 6) {
                    if let cat = entry.category {
                        Text(LocalizedStringKey("cash_book_category_\(cat)"))
                    }
                    if let ref = entry.receiptReference, !ref.isEmpty {
                        Text(verbatim: "· \(ref)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
```

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/CashBook/EntriesListSection.swift
git commit -m "feat(cash-book): expense badge + category/receipt subline (iOS list)" -- ios/VMflow/Views/CashBook/EntriesListSection.swift
```

### Task 3.6: pbxproj-Registrierung + xcstrings + Build

**Files:**
- Modify: `ios/VMflow.xcodeproj/project.pbxproj`
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

- [ ] **Step 1: `ExpenseSheet.swift` an 4 Stellen ins pbxproj**

`ios/VMflow.xcodeproj/project.pbxproj` hat KEINE synchronized groups → `ExpenseSheet.swift` muss manuell registriert werden. Als Vorlage dient `WithdrawalSheet.swift` — suche dessen vier Vorkommen und füge je ein analoges für `ExpenseSheet.swift` hinzu:
  1. **PBXBuildFile** (oben): `XXXX /* ExpenseSheet.swift in Sources */ = {isa = PBXBuildFile; fileRef = YYYY /* ExpenseSheet.swift */; };`
  2. **PBXFileReference**: `YYYY /* ExpenseSheet.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ExpenseSheet.swift; sourceTree = "<group>"; };`
  3. **group children** (die `Views/CashBook`-Gruppe, in der `WithdrawalSheet.swift` gelistet ist): `YYYY /* ExpenseSheet.swift */,`
  4. **PBXSourcesBuildPhase** files: `XXXX /* ExpenseSheet.swift in Sources */,`

Wähle für `XXXX`/`YYYY` neue, im File noch nicht vorkommende 24-stellige Hex-IDs (z. B. die der `WithdrawalSheet`-Einträge nehmen und 1–2 Stellen hochzählen, auf Eindeutigkeit prüfen mit `grep`).

Verifikation der Eindeutigkeit:
```bash
grep -c "ExpenseSheet.swift" ios/VMflow.xcodeproj/project.pbxproj
```
Expected: `4`.

- [ ] **Step 2: Deutsche xcstrings ergänzen**

Gemäß `reference_ios_xcstrings_editing` (Memory): Key = resolvierter `String(localized:)`-Literal bzw. die hier verwendeten `LocalizedStringKey`-Strings; de-only Einträge, du-Ton; chirurgisch einfügen (NIE python-reserialisieren). Neue Keys:

- `cash_book_record_expense` → „Barausgabe"
- `cash_book_amount` → „Betrag"
- `cash_book_category` → „Kategorie"
- `cash_book_receipt_reference` → „Belegnr."
- `cash_book_receipt_reference_placeholder` → „z. B. RE-2026-001"
- `cash_book_description_required` → „Beschreibung (Pflicht)"
- `cash_book_type_expense` → „Ausgabe"
- `cash_book_type_unknown` → „Sonstige"
- `cash_book_category_rent` → „Miete"
- `cash_book_category_goods` → „Wareneinkauf"
- `cash_book_category_cleaning` → „Reinigung"
- `cash_book_category_fees` → „Gebühren"
- `cash_book_category_other` → „Sonstiges"

> `cash_book_cancel`, `cash_book_book_entry`, `cash_book_description` existieren bereits (von WithdrawalSheet) — NICHT duplizieren, nur die neuen Keys hinzufügen.

- [ ] **Step 3: Build (verifiziert Enum-switch, neue Datei, xcstrings)**

Run:
```bash
cd ios && xcodebuild -project VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **`. Bei `BUILD FAILED`: Fehlermeldung lesen — häufigste Ursachen: pbxproj-ID-Kollision, fehlender switch-Fall, xcstrings-Syntax (xcstringstool läuft als Build-Phase und meldet JSON-Fehler).

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow.xcodeproj/project.pbxproj ios/VMflow/Resources/Localizable.xcstrings
git commit -m "feat(cash-book): register ExpenseSheet + German strings (iOS)" -- ios/VMflow.xcodeproj/project.pbxproj ios/VMflow/Resources/Localizable.xcstrings
```

---

## Final Verification

- [ ] **DB:** `cd Docker/supabase && supabase migration up` sauber; CHECK-Test (Task 1.1 Step 3) bestätigt Annahme/Ablehnung.
- [ ] **PWA:** `cd management-frontend && npx vitest run` alle grün; `npx nuxi typecheck` keine neuen Fehler; manuell: Barausgabe erfassen → erscheint als „Ausgabe" mit Kategorie-Badge + Beleg, Bestand sinkt, Storno funktioniert, PDF zeigt Kategorie/Beleg.
- [ ] **iOS:** `xcodebuild ... build` SUCCEEDED; manuell im Simulator: Ausgabe-Sheet bucht, Liste zeigt Badge + Kategorie/Beleg.
- [ ] **Backward-compat:** Alte Buchungen (ohne category/receipt) laden weiter in PWA + iOS; `verifyIntegrity` weiterhin grün (Hash-Formel unverändert).

## Rollout-Hinweis

Den iOS-Build mit `.unknown`-Fallback **vor** der ersten produktiv gebuchten Ausgabe ausrollen, damit ältere App-Instanzen die neue Buchungsart nicht beim Decoden werfen. (PWA unkritisch.)
