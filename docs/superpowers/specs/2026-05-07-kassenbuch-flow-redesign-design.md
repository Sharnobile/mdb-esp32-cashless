# Kassenbuch Flow & Labels Redesign

**Date:** 2026-05-07
**Status:** Draft

## Problem

The Kassenbuch page (`management-frontend/app/pages/cash-book/index.vue`) confuses users for three reasons:

1. **Inconsistent terminology.** The page is called *Kassenbuch*, the entity is sometimes called *Barkasse* and sometimes *Kasse*, and KPI labels mix in *Bargeldeinnahmen*. Users cannot tell whether these are different concepts.

2. **Ambiguous action labels.** "Entnahme erfassen" and "Auszahlung erfassen" do not say *what* is being withdrawn from *where to where*. The default description on a withdrawal is `"Geldentnahme - Bankeinzahlung"`, which mixes two distinct steps (machine→cash box and cash box→bank) into one event.

3. **No visible flow.** The actual money path — *machine → cash box → bank* — is nowhere on the screen. Five action buttons sit in a single horizontal row with equal weight, and the user has to mentally reconstruct which buttons belong to which step.

The intended workflow, as the operator describes it: cash sits in the vending machines; the operator periodically empties the machines and stores the cash in a physical cash box (the *Barkasse*); later, the operator brings the cash to the bank and deposits it into the bank account. The current UI does not reflect this two-stage flow at all.

## Goals

- Consistent terminology: one word for the entity (*Barkasse*) and one word for the page (*Kassenbuch*).
- Source/target-oriented action labels that name *what* moves *from where to where* (e.g. "Geld aus Automat entnehmen", "Geld auf Bank einzahlen").
- A flow visualisation at the top of the page showing three stations — *In Automaten* → *In der Kasse* → *Letzte Bankeinzahlung* — with the two primary actions placed between the stations they connect.
- Per-Barkasse threshold for visually emphasising the bank-deposit CTA (default 500 €).
- A "Gesamten Bestand" quick-fill button on the bank-deposit modal for the common case of fully emptying the cash box.
- All entry-type labels and the PDF export pick up the new wording; the German `type` strings stored in the database stay unchanged.

## Non-Goals

- No changes to the GoBD hash-chain algorithm, the immutability of entries, or the reversal logic.
- No changes to the `cash_book_entries.type` enum strings (`'initial' | 'withdrawal' | 'correction' | 'payout' | 'reversal'`). Only the *displayed* label changes — the database value stays the same so existing rows stay valid and the hash chain stays intact.
- No new RPCs or edge functions. The existing `get_theoretical_cash` RPC already returns everything the new flow visualisation needs.
- No multi-step wizard for collecting cash from multiple machines in one tour. One Barkasse-Buchung per modal call, as today.
- No reconciliation against actual bank statements. Station 3 shows what the operator booked into the system — not what the bank confirms.
- No real-time updates of "In Automaten" via Supabase realtime. The value refreshes on page load, modal open, and after a new entry — same cadence as today.

## Terminology

Used consistently throughout UI, modals, table, PDF, and i18n keys:

| Concept | Term |
|---|---|
| Entity (one row in `cash_books`) | **Barkasse** |
| Page / route `/cash-book` | **Kassenbuch** |
| Action: machine → cash box | **Geld aus Automat entnehmen** |
| Action: cash box → bank | **Geld auf Bank einzahlen** |
| Action: manual adjustment | Korrektur erfassen *(unchanged)* |
| Action: undo an entry | Eintrag stornieren *(unchanged)* |

Entry-type labels in the table and PDF:

| `type` (DB) | Old label | New label |
|---|---|---|
| `initial` | Anfangsbestand | Anfangsbestand *(unchanged)* |
| `withdrawal` | Entnahme | **Aus Automat** |
| `payout` | Auszahlung | **Bankeinzahlung** |
| `correction` | Korrektur | Korrektur *(unchanged)* |
| `reversal` | Storno | Storno *(unchanged)* |

Default description copy for new entries:

| Action | Old default | New default |
|---|---|---|
| Withdrawal | `"Geldentnahme - Bankeinzahlung"` | `"Geldentnahme aus Automat"` |
| Payout | `"Auszahlung auf Bankkonto"` | `"Bankeinzahlung"` |

KPI/summary labels:

| Old | New |
|---|---|
| Bargeldeinnahmen | **Aus Automaten gesamt** |
| Total Withdrawals (en) | Cash Collected from Machines |

## Page Layout

### Vorher (5 sections, top to bottom)

1. Header (selector, PDF, new-Barkasse)
2. 4 KPI cards (Aktueller Stand · Bargeldeinnahmen · Gesamtkorrekturen · Integritätsprüfung)
3. Theoretical-cash banner (only when cash sales > 0 since last entry)
4. 5 equal-weight buttons (Entnahme · Korrektur · Auszahlung · Automaten zuweisen · Löschen)
5. Entries table + GoBD footer

### Nachher (4 sections)

1. Header (unchanged)
2. **Flow visualisation** — 3 stations + 2 primary CTAs (replaces the old #2, #3, and the two relevant buttons from #4)
3. **Secondary toolbar** — small buttons for Korrektur · Automaten verwalten · PDF · ⋯ Mehr
4. Entries table with inline stats strip + GoBD footer (same table, new labels)

### Flow visualisation — desktop

```
┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
│ IN AUTOMATEN     │      │ IN DER KASSE     │      │ LETZTE BANK-     │
│                  │ ───▶ │                  │ ───▶ │ EINZAHLUNG       │
│   78,50 €        │      │   234,00 €       │      │  480,00 €        │
│                  │      │ seit 15.04.      │      │  vor 5 Tagen     │
│   Automat A: 45 €│      │                  │      │                  │
│   Automat B: 33 €│      │                  │      │                  │
└──────────────────┘      └──────────────────┘      └──────────────────┘
        │                          │
        ▼                          ▼
 ┌──────────────────┐       ┌──────────────────┐
 │ ✓ Aus Automat    │       │  Auf Bank        │
 │   entnehmen      │       │  einzahlen       │
 │ (grün, primär)   │       │ (sekundär)       │
 └──────────────────┘       └──────────────────┘
```

- Three station cards in a single row, each card shows one number + a one-line subtitle.
- A short chevron arrow between cards (purely visual; no interaction).
- Two action buttons sit directly under the arrows.
- The arrow + button visually associates each action with the *step* it represents (machine→cash box, cash box→bank).

### Flow visualisation — mobile

The same three stations, stacked vertically with downward arrows:

```
┌──────────────────┐
│ IN AUTOMATEN     │
│   78,50 €        │
│ ▾ Details        │
└──────────────────┘
        ↓
  [✓ Aus Automat
     entnehmen]
        ↓
┌──────────────────┐
│ IN DER KASSE     │
│   234,00 €       │
└──────────────────┘
        ↓
  [Auf Bank
   einzahlen]
        ↓
┌──────────────────┐
│ LETZTE BANK-     │
│ EINZAHLUNG       │
│ vor 5 Tagen      │
│ 480,00 €         │
└──────────────────┘
```

### Station data sources

| Station | Value | Source |
|---|---|---|
| 1 — In Automaten | `cash_sales_since` from `get_theoretical_cash` RPC; per-machine list from same RPC | Already returned today; nothing new to fetch. The per-machine list is **always expanded** (no toggle). |
| 2 — In der Kasse | `currentBalance` computed (latest entry's `balance_after`) | Already computed today. Subtitle shows `"seit <last_entry_at>"`. |
| 3 — Letzte Bankeinzahlung | The most recent non-reversed entry with `type = 'payout'` | New client-side derivation from the entries already loaded. If none exists, render "Noch keine". |

### CTA emphasis

The flow visualisation has two symmetric "action needed" cues so the user is never left wondering which step is overdue:

- **"Aus Automat entnehmen" CTA** gets a subtle amber ring whenever `cash_sales_since > 0` — i.e. as soon as any assigned machine has booked a cash sale that has not been collected yet. This replaces the conditional blue banner that used to appear above the buttons today.
- **"Auf Bank einzahlen" CTA** gets the same amber ring whenever `currentBalance >= cash_books.bank_deposit_threshold`. Below the threshold the button stays in its default secondary style.

The threshold is a per-Barkasse setting — different routes have different cash volumes. Default: **500 €**, minimum **1 €** (the settings modal enforces this; setting it to 0 is rejected to avoid the "always highlighted" trivial case).

### Secondary toolbar

A second row of smaller buttons under the flow visualisation:

```
[+ Korrektur erfassen]  [Automaten verwalten]  [PDF exportieren]  [⋯ Mehr]
```

The "⋯ Mehr" menu (a popover) contains rare/destructive actions:

- *Einstellungen* — opens a small modal to edit the `bank_deposit_threshold`
- *Barkasse löschen* — same multi-step delete flow as today

### Inline stats strip + entries table

The 3 remaining KPI cards (Aus Automaten gesamt · Korrekturen · Integritätsprüfung) collapse into a single text strip directly above the entries table:

```
Buchungshistorie                                          GoBD-konform ✓
─────────────────────────────────────────────────────────────────────────
Aus Automaten gesamt: 12.450 €  ·  Korrekturen: 5  ·  47/47 verifiziert
                                                              [30 Tage ▼]
```

This places the analytical numbers right next to the data they summarise, frees up vertical space at the top of the page for the flow visualisation, and reduces "card noise".

## Modal Changes

### "Geld aus Automat entnehmen" (was: Entnahme erfassen)

```
┌─────────────────────────────────────────────────────┐
│ Geld aus Automat entnehmen                       ✕ │
├─────────────────────────────────────────────────────┤
│                                                     │
│ Erwartet aus Automaten (seit letzter Entnahme):    │
│ ┌─────────────────────────────────────────────────┐ │
│ │  78,50 €                                        │ │
│ │   Automat A:  45,00 €                           │ │
│ │   Automat B:  33,50 €                           │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ Tatsächlich gezählt (EUR)                          │
│ [    78,50    ]                                     │
│                                                     │
│ ✓ Stimmt mit Erwartung überein                     │
│                                                     │
│ Aus welchem Automat? (optional)                    │
│ [▼ —                                            ]  │
│                                                     │
│ Beschreibung                                        │
│ [Geldentnahme aus Automat                       ]  │
│                                                     │
│              [Abbrechen]  [Entnahme buchen]        │
└─────────────────────────────────────────────────────┘
```

Changes vs. today: title, default description, expected-block label. Logic (counted vs. expected difference banner, optional machine selector, RPC call) is unchanged.

### "Geld auf Bank einzahlen" (was: Auszahlung erfassen)

```
┌─────────────────────────────────────────────────────┐
│ Geld auf Bank einzahlen                          ✕ │
├─────────────────────────────────────────────────────┤
│                                                     │
│ Aktueller Kassenstand: 234,00 €                    │
│                                                     │
│ Betrag zur Bank (EUR)                              │
│ [    234,00   ]    [Gesamten Bestand]              │
│                                                     │
│ Beschreibung                                        │
│ [Bankeinzahlung                                 ]  │
│                                                     │
│              [Abbrechen]  [Einzahlung buchen]      │
└─────────────────────────────────────────────────────┘
```

The new "Gesamten Bestand" quick-fill button writes `currentBalance` into the amount field. Typical case: emptying the cash box completely on a bank trip.

### "Einstellungen" (new)

Opened from the "⋯ Mehr" menu. Single field:

```
┌─────────────────────────────────────────────────────┐
│ Barkasse-Einstellungen                           ✕ │
├─────────────────────────────────────────────────────┤
│                                                     │
│ Erinnerung an Bankeinzahlung ab Kassenstand (EUR)  │
│ [    500,00   ]                                     │
│                                                     │
│ Wenn der Kassenstand diesen Wert erreicht, wird   │
│ der Button "Auf Bank einzahlen" hervorgehoben.     │
│                                                     │
│              [Abbrechen]  [Speichern]              │
└─────────────────────────────────────────────────────┘
```

### Create-Barkasse modal

Add one optional field below the existing "Anfangsbestand":

```
Erinnerung ab Kassenstand (EUR)   [   500,00   ]
```

Default 500 € so the user can simply leave it as-is.

## Database

One new column, idempotent migration:

```sql
ALTER TABLE public.cash_books
  ADD COLUMN IF NOT EXISTS bank_deposit_threshold float8 NOT NULL DEFAULT 500;
```

No backfill needed — the default applies to existing rows automatically.

No other schema changes. The `cash_book_entries.type` enum stays exactly as it is (`'initial' | 'withdrawal' | 'correction' | 'payout' | 'reversal'`), so the GoBD hash chain on existing entries continues to verify.

The migration file follows the project's 14-digit `YYYYMMDDHHMMSS_<snake_case>.sql` naming convention — `Docker/supabase/migrations/20260507000000_bank_deposit_threshold.sql` — so it sorts correctly in `Docker/update.sh`'s lexicographic apply order and matches every existing migration's format. As always: never edit existing migrations; always add a new one.

## File Layout

```
management-frontend/app/
├── pages/cash-book/
│   └── index.vue                       # REWRITTEN — slimmer page, composes the new components
├── components/cash-book/               # NEW directory
│   ├── FlowVisualisation.vue           # 3 stations + 2 CTAs (desktop) / vertical stack (mobile)
│   ├── StationInMachines.vue           # station 1 — sum + per-machine list
│   ├── StationInBox.vue                # station 2 — current balance + last-entry date
│   ├── StationLastBankDeposit.vue      # station 3 — last payout entry, "Noch keine" if absent
│   ├── WithdrawalModal.vue             # extracted from today's inline modal
│   ├── BankDepositModal.vue            # extracted, with new "Gesamten Bestand" button
│   ├── CorrectionModal.vue             # extracted
│   ├── ReversalModal.vue               # extracted
│   ├── AssignMachinesModal.vue         # extracted
│   ├── BarkasseSettingsModal.vue       # NEW — edits bank_deposit_threshold
│   ├── DeleteBarkasseModal.vue         # extracted
│   ├── CreateBarkasseModal.vue         # extracted, gets new threshold field
│   ├── SecondaryToolbar.vue            # the small action row + ⋯ Mehr menu
│   └── EntriesTable.vue                # extracted, picks up new labels
└── composables/
    └── useCashBook.ts                  # MODIFIED — add `lastBankDeposit` derived ref + threshold CRUD
```

The current `pages/cash-book/index.vue` is 1,110 lines. The rewrite reduces it to a thin composition page (~150 lines) that wires the components together. Each new component is self-contained with its own modal state, refs, and Supabase calls — same pattern as `account/` and `settings/` use.

## Composable: `useCashBook`

Additions:

```ts
// New computed ref derived from existing entries.
// Invariant: `entries.value` is sorted DESC by `entry_number` (set by
// fetchEntries' `.order('entry_number', { ascending: false })`), so the
// first matching payout is the most recent one.
const lastBankDeposit = computed<CashBookEntry | null>(() =>
  entries.value.find(e => e.type === 'payout' && !e.is_reversed) ?? null
)

// New CRUD for the threshold field
async function updateBankDepositThreshold(cashBookId: string, threshold: number)
```

`CashBook` interface gains `bank_deposit_threshold: number`. No other interface changes.

The `currentBalance` / `totalWithdrawals` / `totalCorrections` computeds and all CRUD methods are unchanged.

## i18n

The existing `cashBook.*` namespace stays. New keys are added; old keys are renamed *only* where the displayed wording changes meaningfully. We do not rename keys whose value happens to change ("Entnahme" → "Aus Automat") — keeping the same key avoids touching every consumer for a pure copy edit.

| Key | de (new) | en (new) |
|---|---|---|
| `cashBook.recordWithdrawal` | Geld aus Automat entnehmen | Take cash from machine |
| `cashBook.recordPayout` | Geld auf Bank einzahlen | Deposit to bank |
| `cashBook.typeWithdrawal` | Aus Automat | From machine |
| `cashBook.typePayout` | Bankeinzahlung | Bank deposit |
| `cashBook.totalWithdrawals` | Aus Automaten gesamt | Cash collected from machines |
| `cashBook.lastBankDeposit` *(new)* | Letzte Bankeinzahlung | Last bank deposit |
| `cashBook.noBankDepositYet` *(new)* | Noch keine | None yet |
| `cashBook.inMachines` *(new)* | In Automaten | In machines |
| `cashBook.inBox` *(new)* | In der Kasse | In cash box |
| `cashBook.bankDepositThreshold` *(new)* | Erinnerung an Bankeinzahlung ab Kassenstand | Bank-deposit reminder threshold |
| `cashBook.thresholdHint` *(new)* | Wenn der Kassenstand diesen Wert erreicht, wird der Button "Auf Bank einzahlen" hervorgehoben. | When the cash-box balance reaches this value, the "Deposit to bank" button is highlighted. |
| `cashBook.fullAmount` *(new)* | Gesamten Bestand | Full amount |
| `cashBook.barkasseSettings` *(new)* | Barkasse-Einstellungen | Cash-box settings |
| `cashBook.expectedFromMachines` *(new)* | Erwartet aus Automaten (seit letzter Entnahme) | Expected from machines (since last withdrawal) |
| `cashBook.matchesExpected` *(new)* | Stimmt mit Erwartung überein | Matches expected amount |

Default-description copy lives in code (Vue refs), not i18n — same as today. Both German strings are updated in place.

## PDF Export

The `exportPdf` function in `pages/cash-book/index.vue` (lines 382–458 today) keeps the same overall structure (header, summary block, table, GoBD footer). Two changes:

1. The summary line "Bargeldeinnahmen" becomes "Aus Automaten gesamt" (uses `cashBook.totalWithdrawals` i18n key, which now resolves to the new wording).
2. The table's "Art" column shows the new entry-type labels via the existing `typeLabel()` helper — which now reads from the updated i18n keys, so no logic change is needed.

Hash, GoBD footer, activation timestamp, and entry count are all unchanged.

## Backward Compatibility

This is a frontend-only redesign with one additive DB column.

- **Existing entries:** all rows in `cash_book_entries` keep their `type`, `amount`, `balance_after`, and `hash` exactly as written. The hash chain continues to verify because we never change a stored value — only the *displayed* labels change.
- **Existing Barkassen:** all rows in `cash_books` get `bank_deposit_threshold = 500` from the column default. No migration data step required.
- **Existing PDFs:** previously exported PDFs are unaffected (they are static files). Future PDFs use new labels — there is no expectation that future PDFs match old ones byte-for-byte.
- **Firmware:** untouched. The cash book is server-side only.
- **Edge functions / MQTT:** untouched.
- **API consumers:** the `cashBook.*` i18n keys whose *values* changed are expected to be consumed only by this page, but this is verified as **build-order step 0** (a `grep -rn 'cashBook\\.\\(recordWithdrawal\\|recordPayout\\|typeWithdrawal\\|typePayout\\|totalWithdrawals\\)' management-frontend/app` audit before any code changes). Any other consumer found gets the same wording update in the same commit.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Pulling 1,110 lines apart into 13 components misses a reactive ref or shared state | Extract one component at a time; run `nuxi typecheck` and the dev server after each. Start with the smallest leaf (StationInMachines) and work outward. |
| Mobile flow visualisation cramps on small screens | Stack vertically below the `sm:` breakpoint; per-machine list collapses to a smaller font but stays expanded. Test on iPhone SE viewport (375 × 667) **with the BottomTabBar visible** (it takes ~56 px) so the third station card stays reachable on the smallest device the PWA supports. |
| Threshold default of 500 € feels too low/high for some operators | Per-Barkasse setting, edited via the new settings modal. Operator overrides as needed; the default is just a starting point. |
| User confused by "Letzte Bankeinzahlung" if there has never been one | Render explicit "Noch keine" placeholder; do not leave the card blank. |
| New i18n keys missing in en or de cause `[missing translation]` text | Add both languages in the same commit as the component using them; smoke-test with the language switcher. |
| Hash-chain regression from accidentally rewriting `typeLabel()` to use a different `type` string when inserting new entries | The `cash_book_entries.type` field is set in `useCashBook.createEntry` and never reads from i18n. Confirmed by inspection — the rename is display-only. |

## Build Order

0. **i18n consumer audit.** Run `grep -rn 'cashBook\.\(recordWithdrawal\|recordPayout\|typeWithdrawal\|typePayout\|totalWithdrawals\)' management-frontend/app` and capture the result. Any consumer outside `pages/cash-book/` and the new `components/cash-book/` is added to the wording-update list before step 2.
1. **Migration.** Add `Docker/supabase/migrations/20260507000000_bank_deposit_threshold.sql` with `ADD COLUMN IF NOT EXISTS bank_deposit_threshold float8 NOT NULL DEFAULT 500`. Run `supabase migration up` (never `db reset`).
2. **i18n.** Add the new keys + change the values of `recordWithdrawal`, `recordPayout`, `typeWithdrawal`, `typePayout`, `totalWithdrawals` in both `de.json` and `en.json`.
3. **Composable.** Extend `CashBook` interface with `bank_deposit_threshold`. Add `lastBankDeposit` computed and `updateBankDepositThreshold` method to `useCashBook`.
4. **Extract leaf modals.** Move `WithdrawalModal`, `BankDepositModal`, `CorrectionModal`, `ReversalModal`, `AssignMachinesModal`, `DeleteBarkasseModal`, `CreateBarkasseModal` out of the page into `components/cash-book/`. Each move + verify (the page still works) before the next.
5. **Add new modals.** `BarkasseSettingsModal` (threshold edit) and the "Gesamten Bestand" button on `BankDepositModal`. Update default description copy to the new strings.
6. **Build flow visualisation.** Create `StationInMachines`, `StationInBox`, `StationLastBankDeposit`, then `FlowVisualisation` that composes them. Add the threshold-based ring/pulse on the deposit CTA.
7. **Build secondary toolbar.** `SecondaryToolbar` with the four buttons + ⋯ Mehr popover wiring to existing modals + the new settings modal.
8. **Extract `EntriesTable`** with the inline stats strip; verify entry-type labels resolve to the new strings; verify the GoBD-konform pill still renders.
9. **Rewrite `pages/cash-book/index.vue`** as the thin composition page. Remove the old KPI cards, the theoretical-cash banner, and the 5-button row. Verify in browser: empty state, single-Barkasse case, multi-Barkasse case, mobile viewport.
10. **PDF export.** Confirm `exportPdf` still produces a valid PDF (label changes ride for free on the i18n update). One smoke test export per Barkasse with mixed entry types.
11. **Smoke test the full flow.** Log in, create a new Barkasse with a custom threshold, assign two machines, simulate a sale, open the withdrawal modal, book an entry, verify the in-machines station drops to 0, raise the cash-box balance over the threshold, see the deposit CTA highlighted, do a deposit with "Gesamten Bestand", confirm last-bank-deposit station updates.

## Out of Scope (Future)

- Multi-machine wizard for collecting from a route in one tour (similar to the existing refill wizard but for cash collection).
- Reconciliation against actual bank statement imports.
- Per-machine cash-collection history view.
- Realtime updates of "In Automaten" via Supabase realtime channels.
- Renaming the `cash_book_entries.type` enum values to the new German labels — would invalidate the GoBD hash chain on every existing row.
- Mobile bottom-tab-bar entry for the Kassenbuch page.
