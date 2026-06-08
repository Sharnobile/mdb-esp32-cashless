# Suppressed sales in the Sales list + removal reason — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Interleave auto-removed (suppressed) sales into the normal Sales list — visually marked as non-counting (dimmed + "Auto-removed" badge + strikethrough price) — and replace the static removal reason with the real circumstances (clock unsynced + gap to the matched sale), on both the PWA and native iOS, with no DB/webhook change.

**Architecture:** Frontend-only. Both clients already load the suppressed rows; we add the matched sale's `created_at` via the existing `matched_sale_id` FK, derive the reason with a pure helper, and merge suppressed rows into the day-grouped Sales feed. Revenue/chart keep reading real sales only, so suppressed never affect money.

**Tech Stack:** Nuxt 4 PWA (Vue 3 `<script setup>`, vitest), SwiftUI (`ios/VMflow`), Supabase PostgREST (FK embedding).

**Spec:** `docs/superpowers/specs/2026-06-08-suppressed-sales-in-list-and-reason-design.md`

---

## CRITICAL working-tree & commit rules (read before any commit)

The working tree has **parallel in-flight work that must never be committed by this plan**:
- Modified iOS (leave untouched): `ios/NotificationService/Info.plist`, `ios/VMflow/Models/CashBook.swift`, `ios/VMflow/Resources/Info.plist`, `ios/VMflow/Resources/Localizable.xcstrings`, `ios/VMflow/ViewModels/RefillWizardViewModel.swift`, `ios/VMflow/Views/CashBook/WithdrawalSheet.swift`, `ios/VMflow/Views/Refill/RefillSummaryView.swift`
- Untracked (leave untouched): `Docker/supabase/functions/mqtt-webhook/deno.lock`, `MMM-VMflow/`, `ios/VMflow.xcodeproj/xcshareddata/`, and any other untracked path not created by this plan.

**Rules:**
- **NEVER `git add -A`, `git add .`, or `git add <dir>/`.** Always `git add <exact file paths>` listed in each commit step.
- The PWA page path `management-frontend/app/pages/machines/[id].vue` has literal brackets — **single-quote it in every shell command** (the user's shell is zsh; unquoted `[id]` globs and the command aborts).
- Stay on `main` (the user works directly on main; no worktrees).
- Before each iOS commit, run `git status -s <the exact files>` to confirm only your changes are staged.
- **vitest needs Node ≥ 20.** If `npx vitest` errors with `ERR_UNKNOWN_BUILTIN_MODULE: node:fs/promises`, run first (inline): `export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; nvm use default`
- No backend changes in this plan (no migration, no `supabase` commands).
- Commit trailer on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

All files this plan edits are clean at HEAD (committed/pushed in the prior milestone); scoped commits are safe.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `management-frontend/app/composables/useSuppressedSales.ts` | Add `matched` to `SuppressedSale` + the select; export pure `suppressedReasonParts()` + `buildSalesFeedDays()` |
| `management-frontend/app/composables/__tests__/useSuppressedSales.test.ts` | **Extend** (keep `restore` tests): tests for the two new pure helpers |
| `management-frontend/app/pages/machines/[id].vue` | `salesFeed` computed (merge); marked suppressed row in the Sales list; `suppressedReasonText()`; Device Health card reason → builder |
| `management-frontend/i18n/locales/en.json`, `de.json` | Badge + reason-fragment keys |
| `ios/VMflow/Models/SuppressedSale.swift` | `matched` field + `reasonText` computed |
| `ios/VMflow/ViewModels/MachineDetailViewModel.swift` | Add `matched:sales!matched_sale_id(created_at)` to the suppressed select |
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | `SalesFeedItem`/`groupFeedByDay`; Sales tab unified feed; `SuppressedSaleListRow`; `SuppressedSaleRow` reason → `reasonText` |

---

## Chunk 1: PWA — reason builder, feed merge, list rendering, i18n

### Task 1: Composable — `matched` join + pure helpers (TDD)

**Files:**
- Modify: `management-frontend/app/composables/useSuppressedSales.ts`
- Modify (extend): `management-frontend/app/composables/__tests__/useSuppressedSales.test.ts`

- [ ] **Step 1: Write the failing tests** — append to `management-frontend/app/composables/__tests__/useSuppressedSales.test.ts` (keep the existing imports + `restore` describe block; add the new import and two describe blocks):

At the top, change the import line `import { useSuppressedSales } from '../useSuppressedSales'` to also import the helpers:
```ts
import { useSuppressedSales, suppressedReasonParts, buildSalesFeedDays } from '../useSuppressedSales'
```

Then append:
```ts
describe('suppressedReasonParts', () => {
  it('clock not synced when device_created_at present', () => {
    const r = suppressedReasonParts({ device_created_at: '2026-06-05T10:00:00Z', received_at: '2026-06-05T10:00:03Z', matched: { created_at: '2026-06-05T10:00:00Z' } } as any)
    expect(r.clock).toBe('unsynced')
    expect(r.gapSeconds).toBe(3)
  })
  it('no clock when device_created_at is null', () => {
    const r = suppressedReasonParts({ device_created_at: null, received_at: '2026-06-05T10:00:05Z', matched: { created_at: '2026-06-05T10:00:00Z' } } as any)
    expect(r.clock).toBe('noclock')
    expect(r.gapSeconds).toBe(5)
  })
  it('gapSeconds null when matched missing', () => {
    const r = suppressedReasonParts({ device_created_at: '2026-06-05T10:00:00Z', received_at: '2026-06-05T10:00:03Z', matched: null } as any)
    expect(r.gapSeconds).toBeNull()
  })
})

describe('buildSalesFeedDays', () => {
  const dayKey = (ts: number) => new Date(ts).toISOString().slice(0, 10)
  const now = Date.parse('2026-06-05T12:00:00Z')
  const windowMs = 30 * 24 * 60 * 60 * 1000

  it('interleaves real + suppressed by time desc; saleCount counts real only', () => {
    const sales = [
      { id: 'a', created_at: '2026-06-05T10:00:00Z' },
      { id: 'b', created_at: '2026-06-05T10:00:05Z' },
    ]
    const suppressed = [{ id: 's1', received_at: '2026-06-05T10:00:03Z' }]
    const groups = buildSalesFeedDays(sales as any, suppressed as any, { nowMs: now, windowMs, dayKey })
    expect(groups).toHaveLength(1)
    expect(groups[0].items.map(i => i.key)).toEqual(['sale-b', 'sup-s1', 'sale-a'])
    expect(groups[0].saleCount).toBe(2)
  })

  it('drops suppressed older than the window', () => {
    const sales = [{ id: 'a', created_at: '2026-06-05T10:00:00Z' }]
    const old = new Date(now - windowMs - 1000).toISOString()
    const suppressed = [{ id: 'sOld', received_at: old }]
    const groups = buildSalesFeedDays(sales as any, suppressed as any, { nowMs: now, windowMs, dayKey })
    const keys = groups.flatMap(g => g.items.map(i => i.key))
    expect(keys).not.toContain('sup-sOld')
    expect(keys).toContain('sale-a')
  })

  it('groups by day, days sorted desc', () => {
    const sales = [
      { id: 'a', created_at: '2026-06-05T10:00:00Z' },
      { id: 'b', created_at: '2026-06-04T10:00:00Z' },
    ]
    const groups = buildSalesFeedDays(sales as any, [] as any, { nowMs: now, windowMs, dayKey })
    expect(groups.map(g => g.key)).toEqual(['2026-06-05', '2026-06-04'])
  })
})
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useSuppressedSales.test.ts`
Expected: FAIL — `suppressedReasonParts is not a function` / `buildSalesFeedDays is not a function`.

- [ ] **Step 3: Implement** in `management-frontend/app/composables/useSuppressedSales.ts`.

(a) Extend the interface — add to `SuppressedSale`:
```ts
  matched?: { created_at: string } | null
```

(b) Add the matched embed to BOTH selects (`fetchRows` and `fetchMore`): change
```ts
.select('*, products(name, image_path)')
```
to
```ts
.select('*, products(name, image_path), matched:sales!matched_sale_id(created_at)')
```
(If PostgREST rejects the `matched_sale_id` column hint at runtime, the FK constraint name fallback is `matched:sales!suppressed_sales_matched_sale_id_fkey(created_at)` — `suppressed_sales` has exactly one FK to `sales`, so the column-name hint should resolve.)

(c) Add the two pure, exported helpers at module top level (OUTSIDE the `useSuppressedSales` function, e.g. just below the `SuppressedSale` interface):
```ts
/** Pure: derive the removal-reason parts from a suppressed row (no i18n here). */
export function suppressedReasonParts(row: {
  device_created_at: string | null
  received_at: string
  matched?: { created_at: string } | null
}): { clock: 'unsynced' | 'noclock'; gapSeconds: number | null } {
  const clock = row.device_created_at == null ? 'noclock' : 'unsynced'
  let gapSeconds: number | null = null
  const matchedTs = row.matched?.created_at ? Date.parse(row.matched.created_at) : NaN
  if (!Number.isNaN(matchedTs)) {
    gapSeconds = Math.round(Math.abs(Date.parse(row.received_at) - matchedTs) / 1000)
  }
  return { clock, gapSeconds }
}

export type SalesFeedItem =
  | { kind: 'sale'; key: string; ts: number; sale: any }
  | { kind: 'suppressed'; key: string; ts: number; row: any }
export interface SalesFeedDay { key: string; items: SalesFeedItem[]; saleCount: number }

/**
 * Pure: merge real sales + suppressed rows into day groups (days desc, items
 * desc within a day). Suppressed older than nowMs - windowMs are dropped so an
 * old suppressed-only day group can't dangle past the sales window. `dayKey`
 * is injected (the caller passes the SAME locale-based key salesByDay uses, so
 * a suppressed row buckets into the same calendar day as its sibling sale —
 * never use toISOString().slice for the real key, it can differ near midnight).
 * saleCount counts real sales only.
 */
export function buildSalesFeedDays(
  sales: any[],
  suppressed: any[],
  opts: { nowMs: number; windowMs: number; dayKey: (ts: number) => string },
): SalesFeedDay[] {
  const items: SalesFeedItem[] = []
  for (const s of sales) {
    items.push({ kind: 'sale', key: `sale-${s.id}`, ts: Date.parse(s.created_at), sale: s })
  }
  const cutoff = opts.nowMs - opts.windowMs
  for (const r of suppressed) {
    const ts = Date.parse(r.received_at)
    if (ts >= cutoff) items.push({ kind: 'suppressed', key: `sup-${r.id}`, ts, row: r })
  }
  items.sort((a, b) => b.ts - a.ts)
  const days: SalesFeedDay[] = []
  let cur: SalesFeedDay | null = null
  let curKey = ''
  for (const it of items) {
    const k = opts.dayKey(it.ts)
    if (k !== curKey) { curKey = k; cur = { key: k, items: [], saleCount: 0 }; days.push(cur) }
    cur!.items.push(it)
    if (it.kind === 'sale') cur!.saleCount++
  }
  return days
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useSuppressedSales.test.ts`
Expected: PASS (existing `restore` tests + the new ones).

- [ ] **Step 5: Commit** (exact paths):
```bash
git add management-frontend/app/composables/useSuppressedSales.ts management-frontend/app/composables/__tests__/useSuppressedSales.test.ts
git commit -m "feat(pwa): suppressed-sale reason parts + sales-feed merge helpers (+ matched join)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2: PWA page — merged Sales list, marked rows, reason text, i18n

**Files:**
- Modify: `management-frontend/app/pages/machines/[id].vue`
- Modify: `management-frontend/i18n/locales/en.json`, `de.json`

- [ ] **Step 1: i18n (en)** — in `management-frontend/i18n/locales/en.json`, `suppressedRestoring` is currently the **last** key of `machineDetail` (no trailing comma, followed by `}`). Exact find-and-replace so JSON stays valid (existing key gains a comma; the new last key `reasonNearDup` has none):

Find:
```json
    "suppressedRestoring": "Taking up…"
```
Replace with:
```json
    "suppressedRestoring": "Taking up…",
    "suppressedBadge": "Auto-removed",
    "reasonClockUnsynced": "Clock not synced",
    "reasonNoClock": "Device had no clock",
    "reasonGapEarlier": "identical sale {n}s earlier",
    "reasonNearDup": "near-duplicate of a recent sale"
```

- [ ] **Step 2: i18n (de)** — same exact find-and-replace in `management-frontend/i18n/locales/de.json` (`suppressedRestoring` is likewise the last `machineDetail` key, no trailing comma):

Find:
```json
    "suppressedRestoring": "Wird übernommen…"
```
Replace with:
```json
    "suppressedRestoring": "Wird übernommen…",
    "suppressedBadge": "Automatisch entfernt",
    "reasonClockUnsynced": "Uhr nicht synchronisiert",
    "reasonNoClock": "Gerät hatte keine Uhr",
    "reasonGapEarlier": "identischer Verkauf {n}s früher",
    "reasonNearDup": "Beinahe-Duplikat eines kürzlichen Verkaufs"
```

- [ ] **Step 3: Import the helpers** — in `[id].vue` `<script setup>`, find the existing `useSuppressedSales()` usage and add an import for the pure helpers near the other imports (the composable is auto-imported by Nuxt, but the standalone helpers must be imported explicitly):
```ts
import { suppressedReasonParts, buildSalesFeedDays } from '~/composables/useSuppressedSales'
```
(If the project's import alias differs, match the existing import style; `~/composables/...` is standard Nuxt.)

**Also (pre-existing-bug fix for the markup we re-type below):** check the existing `@tabler/icons-vue` import line (~line 7). The Sales row uses `<IconDeviceMobile>` for the `cashless` channel but this icon is currently **not** imported (no tabler auto-import in this project), so the cashless icon renders nothing. **If** `IconDeviceMobile` is absent from that import, add it (alphabetically/with the others). If it's already there, do nothing. Verify with `grep -n "IconDeviceMobile" 'management-frontend/app/pages/machines/[id].vue'` — expect the import line + the template usage(s).

- [ ] **Step 4: Replace the `salesByDay` computed with `salesFeed`** — find the whole `salesByDay` computed (≈ lines 90–121, `const salesByDay = computed(() => { ... return groups })`) and replace it with:
```ts
// Merged Sales feed: real sales + auto-removed (suppressed) rows, day-grouped.
// Suppressed are shown but excluded from revenue/chart (which read sales.value).
const salesFeed = computed(() => {
  const dayKey = (ts: number) =>
    new Date(ts).toLocaleDateString(locale.value, { year: 'numeric', month: '2-digit', day: '2-digit' })
  const days = buildSalesFeedDays(sales.value, suppressedRows.value, {
    nowMs: Date.now(),
    windowMs: 30 * 24 * 60 * 60 * 1000,
    dayKey,
  })
  const today = new Date()
  const yesterday = new Date(today); yesterday.setDate(yesterday.getDate() - 1)
  const todayKey = dayKey(today.getTime())
  const yesterdayKey = dayKey(yesterday.getTime())
  return days.map((g) => {
    let label: string
    if (g.key === todayKey) label = t('machineDetail.today')
    else if (g.key === yesterdayKey) label = t('machineDetail.yesterday')
    else label = new Date(g.items[0].ts).toLocaleDateString(locale.value, { weekday: 'long', day: 'numeric', month: 'long' })
    return { ...g, label }
  })
})

// Build the reason caption for a suppressed row (i18n).
function suppressedReasonText(row: any): string {
  const { clock, gapSeconds } = suppressedReasonParts(row)
  const clockStr = clock === 'noclock' ? t('machineDetail.reasonNoClock') : t('machineDetail.reasonClockUnsynced')
  const gapStr = gapSeconds != null
    ? t('machineDetail.reasonGapEarlier', { n: gapSeconds })
    : t('machineDetail.reasonNearDup')
  return `${clockStr} · ${gapStr}`
}
```
(`sales`, `suppressedRows`, `locale`, `t` are all already in scope on this page. `suppressedReasonParts`/`buildSalesFeedDays` come from the Step 3 import.)

- [ ] **Step 5: Replace the Sales-list render block** — find the sales history list (≈ lines 1365–1436): the `<div v-else class="space-y-4">` containing `<div v-for="group in salesByDay" ...>`. Replace the inner `v-for="group in salesByDay"` group block (from `<div v-for="group in salesByDay" :key="group.date">` through its matching close `</div>` right before `</div>` that closes the `space-y-4` wrapper) with:
```html
                  <div v-for="group in salesFeed" :key="group.key">
                    <div class="sticky top-0 z-10 mb-2 flex items-center gap-3">
                      <span class="text-xs font-medium text-muted-foreground">{{ group.label }}</span>
                      <span class="text-[10px] tabular-nums text-muted-foreground/60">{{ t('machineDetail.saleCount', { count: group.saleCount }, group.saleCount) }}</span>
                      <div class="h-px flex-1 bg-border" />
                    </div>
                    <div class="rounded-xl border bg-card divide-y">
                      <template v-for="item in group.items" :key="item.key">
                        <!-- Real sale (unchanged behaviour) -->
                        <SwipeToDelete
                          v-if="item.kind === 'sale'"
                          :disabled="!isAdmin"
                          @delete="confirmDeleteSale(item.sale)"
                        >
                          <component
                            :is="saleRoutes.get(item.sale.id) ? NuxtLink : 'div'"
                            :to="saleRoutes.get(item.sale.id) ? `/products/${saleRoutes.get(item.sale.id)}` : undefined"
                            class="group/sale flex items-start gap-3 px-4 py-3"
                            :class="{ 'cursor-pointer hover:bg-muted/50 transition-colors': saleRoutes.get(item.sale.id) }"
                          >
                            <img
                              v-if="saleProduct(item.sale)?.image_url"
                              :src="saleProduct(item.sale)!.image_url!"
                              :alt="saleProduct(item.sale)!.name"
                              class="h-9 w-9 shrink-0 rounded-full object-cover mt-0.5"
                            />
                            <div v-else class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-semibold text-primary mt-0.5">
                              {{ formatCurrency(item.sale.item_price, locale) }}
                            </div>
                            <div class="flex-1 min-w-0">
                              <div class="flex items-start justify-between gap-2">
                                <p class="text-sm font-medium break-words">
                                  {{ saleProduct(item.sale)?.name ?? `${t('machineDetail.item')} #${item.sale.item_number}` }}
                                  <button
                                    v-if="isAdmin"
                                    class="hidden sm:inline-flex ml-1 align-middle rounded-md p-0.5 text-muted-foreground/0 transition-colors group-hover/sale:text-muted-foreground hover:!text-destructive"
                                    @click.stop.prevent="confirmDeleteSale(item.sale)"
                                  >
                                    <IconTrash class="size-3.5" />
                                  </button>
                                </p>
                                <span class="shrink-0 text-sm font-semibold tabular-nums">{{ formatCurrency(item.sale.item_price, locale) }}</span>
                              </div>
                              <div class="mt-0.5 flex items-center justify-between">
                                <div class="flex items-center gap-1.5 text-xs text-muted-foreground">
                                  <span class="whitespace-nowrap">{{ t('machineDetail.slot') }} {{ item.sale.item_number }}</span>
                                  <span class="text-muted-foreground/40">·</span>
                                  <span
                                    class="inline-flex items-center gap-0.5 text-[10px] font-medium uppercase tracking-wide"
                                    :class="item.sale.channel === 'card'
                                      ? 'text-blue-600 dark:text-blue-400'
                                      : item.sale.channel === 'cashless'
                                        ? 'text-violet-600 dark:text-violet-400'
                                        : 'text-emerald-600 dark:text-emerald-400'"
                                  >
                                    <IconCreditCard v-if="item.sale.channel === 'card'" class="size-3" />
                                    <IconDeviceMobile v-else-if="item.sale.channel === 'cashless'" class="size-3" />
                                    <IconCoins v-else class="size-3" />
                                    {{ item.sale.channel }}
                                  </span>
                                </div>
                                <span class="shrink-0 text-[11px] text-muted-foreground tabular-nums">{{ new Date(item.sale.created_at).toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit', second: '2-digit' }) }}</span>
                              </div>
                            </div>
                          </component>
                        </SwipeToDelete>
                        <!-- Auto-removed (suppressed) sale: marked, non-counting, no actions -->
                        <div v-else class="flex items-start gap-3 px-4 py-3 opacity-60">
                          <img
                            v-if="suppressedProduct(item.row)?.image_url"
                            :src="suppressedProduct(item.row)!.image_url!"
                            :alt="suppressedProduct(item.row)!.name"
                            class="h-9 w-9 shrink-0 rounded-full object-cover mt-0.5 grayscale"
                          />
                          <div v-else class="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-muted text-xs font-semibold text-muted-foreground mt-0.5">
                            {{ item.row.item_price != null ? formatCurrency(item.row.item_price, locale) : '—' }}
                          </div>
                          <div class="flex-1 min-w-0">
                            <div class="flex items-start justify-between gap-2">
                              <p class="text-sm font-medium break-words text-muted-foreground">
                                {{ suppressedProduct(item.row)?.name ?? `${t('machineDetail.item')} #${item.row.item_number}` }}
                                <span class="ml-1 inline-flex items-center rounded-full bg-orange-500/10 px-1.5 py-0.5 text-[10px] font-medium text-orange-600 align-middle dark:text-orange-400">{{ t('machineDetail.suppressedBadge') }}</span>
                              </p>
                              <span class="shrink-0 text-sm font-semibold tabular-nums text-muted-foreground line-through">{{ item.row.item_price != null ? formatCurrency(item.row.item_price, locale) : '—' }}</span>
                            </div>
                            <div class="mt-0.5 flex items-center justify-between gap-2">
                              <span class="min-w-0 break-words text-xs text-muted-foreground">{{ suppressedReasonText(item.row) }}</span>
                              <span class="shrink-0 text-[11px] text-muted-foreground tabular-nums">{{ new Date(item.row.received_at).toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit', second: '2-digit' }) }}</span>
                            </div>
                          </div>
                        </div>
                      </template>
                    </div>
                  </div>
```
The empty-state line above it (`<div v-if="sales.length === 0" ...>`) stays as-is (suppressed-only is not shown when there are no real sales — consistent with iOS).

- [ ] **Step 6: Upgrade the Device Health card reason** — in the "Auto-removed duplicates" card, find the reason line (≈ line 2232; the string is unique): `<span>{{ t('machineDetail.suppressedReason') }}</span>` and replace with:
```html
                          <span>{{ suppressedReasonText(row) }}</span>
```
(That card's `v-for="row in suppressedRows"` already exposes `row`. The old `machineDetail.suppressedReason` key becomes unused — leave it; harmless.)

- [ ] **Step 7: Verify no stale `salesByDay` references remain**

Run: `grep -n "salesByDay" 'management-frontend/app/pages/machines/[id].vue'`
Expected: no matches (it was renamed to `salesFeed`).

- [ ] **Step 8: Run the full vitest suite**

Run: `cd management-frontend && npx vitest run`
Expected: all pass (incl. the Task 1 helper tests).

- [ ] **Step 9: Validate i18n JSON + build**

Run: `node -e "JSON.parse(require('fs').readFileSync('management-frontend/i18n/locales/en.json','utf8'));JSON.parse(require('fs').readFileSync('management-frontend/i18n/locales/de.json','utf8'));console.log('json ok')"` → `json ok`
Run: `cd management-frontend && npm run build`
Expected: build completes, no type errors. (If unavailable/too slow, at minimum the vitest suite must pass — note it for the user.)

- [ ] **Step 10: Commit** (single-quote the bracket path; exact paths):
```bash
git add 'management-frontend/app/pages/machines/[id].vue' management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat(pwa): show auto-removed sales in the Sales list (marked) + richer removal reason

Interleave suppressed sales into the day-grouped Sales feed as dimmed,
non-counting rows (Auto-removed badge + strikethrough price + reason);
revenue/chart unchanged. Device Health reason now shows clock + gap.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Chunk 2: iOS — reason text, matched join, unified Sales feed

> **iOS build note:** verification is a manual Xcode build (`xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=<an available sim>' build` — list sims with `xcodebuild -showdestinations -project ios/VMflow.xcodeproj -scheme VMflow`). If Xcode is unavailable, make the edits, read them for compile-correctness, and report that a manual build is required.
>
> **Commit handling:** all three files are clean at HEAD. Before committing, `git status -s <the files>` and confirm only your changes; `git add` exactly those paths; never `git add -A`.

### Task 3: `SuppressedSale` model (`matched` + `reasonText`) + VM select

**Files:**
- Modify: `ios/VMflow/Models/SuppressedSale.swift`
- Modify: `ios/VMflow/ViewModels/MachineDetailViewModel.swift`

- [ ] **Step 1: Add the matched join to the VM select** — in `MachineDetailViewModel.swift`, `loadSuppressedSales()`, change the select string from:
```swift
.select("id, embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, matched_sale_id, reason, product_id, products(name, image_path)")
```
to (append the matched embed):
```swift
.select("id, embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, matched_sale_id, reason, product_id, products(name, image_path), matched:sales!matched_sale_id(created_at)")
```

- [ ] **Step 2: Extend the model** — in `ios/VMflow/Models/SuppressedSale.swift`:

Add a nested type (above or below the struct, file scope):
```swift
struct MatchedSaleRef: Codable, Equatable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}
```
Add the property to `SuppressedSale` (after `products`):
```swift
    /// Matched real sale (created_at) from the matched_sale_id FK join — used for the gap in reasonText.
    let matched: MatchedSaleRef?
```
Add `matched` to `CodingKeys` (it maps to the embed alias `matched`, so add it to the plain list):
```swift
        case id, channel, reason, products, matched
```
Add the `reasonText` computed (after `formattedPrice`):
```swift
    /// Human-readable removal circumstances (hardcoded English, matching the tab).
    /// Clock fragment: the device clock was unsynced (always true for a suppressed
    /// row); null device_created_at means the device had no clock at all. Gap: how
    /// long after the matched sale this re-report arrived (server-arrival separation,
    /// not exact inter-vend time) — a plausibility signal.
    var reasonText: String {
        let clock = deviceCreatedAt == nil ? "Device had no clock" : "Clock not synced"
        if let m = matched?.createdAt {
            let gap = Int(abs(receivedAt.timeIntervalSince(m)).rounded())
            return "\(clock) · identical sale \(gap)s earlier"
        }
        return "\(clock) · near-duplicate of a recent sale"
    }
```

- [ ] **Step 3: Sanity-check** — `SuppressedSale` still `Codable, Identifiable, Equatable`; `MatchedSaleRef` is `Equatable` so the synthesized `Equatable` holds. The decoder tolerates a missing `matched` (optional). No other file references break.

### Task 4: iOS Sales tab — unified feed + marked row; Duplicates reason

**Files:**
- Modify: `ios/VMflow/Views/Machines/MachineDetailView.swift`

- [ ] **Step 1: Add the feed types + grouping** — near the other private grouping helpers in `MachineDetailView` (next to `groupSalesByDay`), add:
```swift
    private enum SalesFeedItem: Identifiable {
        case sale(Sale)
        case suppressed(SuppressedSale)
        var id: String {
            switch self {
            case .sale(let s): return "sale-\(s.id)"
            case .suppressed(let s): return "sup-\(s.id)"
            }
        }
        var date: Date {
            switch self {
            case .sale(let s): return s.createdAt
            case .suppressed(let s): return s.receivedAt
            }
        }
    }

    private struct FeedDayGroup { let date: Date; let items: [SalesFeedItem]; let saleCount: Int }

    private func groupFeedByDay(_ items: [SalesFeedItem]) -> [FeedDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { date in
            let dayItems = grouped[date]!.sorted { $0.date > $1.date }
            let saleCount = dayItems.reduce(0) { acc, it in
                if case .sale = it { return acc + 1 } else { return acc }
            }
            return FeedDayGroup(date: date, items: dayItems, saleCount: saleCount)
        }
    }

    /// Real sales + suppressed rows (only those at/after the oldest visible sale,
    /// so a suppressed-only day can't dangle below the last loaded sale).
    private var salesFeedItems: [SalesFeedItem] {
        var items = viewModel.recentSales.map { SalesFeedItem.sale($0) }
        if let cutoff = viewModel.recentSales.map({ $0.createdAt }).min() {
            items += viewModel.suppressedSales
                .filter { $0.receivedAt >= cutoff }
                .map { SalesFeedItem.suppressed($0) }
        }
        return items
    }
```

- [ ] **Step 2: Render the unified feed in `salesTab`** — replace the populated branch of `salesTab` (the `else` block, the `LazyVStack { let grouped = groupSalesByDay(viewModel.recentSales) ForEach ... }`, ≈ lines 324–338) with:
```swift
            } else {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    let grouped = groupFeedByDay(salesFeedItems)
                    ForEach(grouped, id: \.date) { group in
                        Section {
                            ForEach(group.items) { item in
                                switch item {
                                case .sale(let sale):
                                    SaleRow(sale: sale, trays: viewModel.trays) {
                                        presentProductSheet(for: sale)
                                    }
                                case .suppressed(let s):
                                    SuppressedSaleListRow(sale: s, trays: viewModel.trays)
                                }
                            }
                        } header: {
                            DaySectionHeader(label: dayLabel(for: group.date), count: group.saleCount)
                        }
                    }
                }
                .padding(.horizontal)
```
Leave the `if viewModel.recentSales.isEmpty && !viewModel.isLoading { … "No sales yet" … }` branch and the trailing `.padding(.bottom, 20)` / `.refreshable` unchanged (the closing braces after the replaced block stay).

- [ ] **Step 3: Add the marked in-list row** — add a new view (near `SaleRow` / `SuppressedSaleRow`, file scope):
```swift
// MARK: - Suppressed Sale Row (Sales-list variant: marked, non-counting)

struct SuppressedSaleListRow: View {
    let sale: SuppressedSale
    let trays: [Tray]

    private var productName: String {
        sale.products?.name
            ?? trays.first { $0.itemNumber == sale.itemNumber }?.productName
            ?? "Slot \(sale.itemNumber ?? 0)"
    }
    private var productImagePath: String? {
        sale.products?.imagePath
            ?? trays.first { $0.itemNumber == sale.itemNumber }?.products?.imagePath
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: productImagePath, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(productName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Text("Auto-removed")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                Text(sale.reasonText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(sale.formattedPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .strikethrough(true, color: .secondary)
                    .foregroundStyle(.secondary)
                Text(formatTime(sale.receivedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background { RoundedRectangle(cornerRadius: 12).fill(.regularMaterial) }
        .opacity(0.7)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Upgrade the Duplicates-tab reason line** — in `SuppressedSaleRow` (the dedicated-tab row), replace:
```swift
                Text("likely brownout re-report")
                    .font(.caption2)
                    .foregroundStyle(.orange)
```
with:
```swift
                Text(sale.reasonText)
                    .font(.caption2)
                    .foregroundStyle(.orange)
```

- [ ] **Step 5: Build in Xcode** — build the `VMflow` scheme; expect BUILD SUCCEEDED. Manually verify: the Sales tab interleaves dimmed, strikethrough "Auto-removed" rows (with the clock+gap reason) by day; the day-header count counts real sales only; revenue unchanged; the Duplicates tab still works and shows the same richer reason. (If Xcode unavailable, report that a manual build is required.)

- [ ] **Step 6: Commit** (confirm clean first; exact paths):
```bash
git status -s ios/VMflow/Models/SuppressedSale.swift ios/VMflow/ViewModels/MachineDetailViewModel.swift ios/VMflow/Views/Machines/MachineDetailView.swift
git add ios/VMflow/Models/SuppressedSale.swift ios/VMflow/ViewModels/MachineDetailViewModel.swift ios/VMflow/Views/Machines/MachineDetailView.swift
git commit -m "feat(ios): show auto-removed sales in the Sales tab (marked) + richer removal reason

Interleave suppressed sales into the day-grouped Sales feed as dimmed,
strikethrough 'Auto-removed' rows with a clock+gap reason; counts/revenue
unchanged. Duplicates tab reason now shows the same circumstances.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
If `git status -s` shows unexpected in-flight changes on a file, do NOT commit — leave unstaged and report.

---

## Done criteria
- PWA Sales tab shows auto-removed sales interleaved by day as dimmed, non-counting rows (orange "Auto-removed" badge + strikethrough price + clock/gap reason); revenue + 30-day chart unchanged; `useSuppressedSales` pure helpers unit-tested; vitest suite green; build clean.
- iOS Sales tab shows the same marked rows (unified `SalesFeedItem` feed, day-grouped, real-only count); Duplicates tab unchanged except the richer `reasonText`; builds in Xcode.
- Reason everywhere reads "Clock not synced / Device had no clock · identical sale Ns earlier / near-duplicate …".
- Frontend-only; no DB/webhook/migration change; no unrelated/in-flight files committed.
```
