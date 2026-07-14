# Show auto-removed (suppressed) sales in the Sales list + explain the removal reason

**Date:** 2026-06-08
**Area:** `management-frontend` (PWA) + `ios/VMflow` (native iOS). **Frontend-only — no DB/webhook/edge-function change.**
**Type:** Additive UI — interleave suppressed sales into the normal Sales list (visually marked, non-counting) and replace the static removal reason with the real circumstances.

## Goal

Two operator-facing improvements to the brownout auto-removed (suppressed) sales shipped in the prior milestone:

1. **Show suppressed sales in the normal Sales list too**, interleaved chronologically with real sales but **visually marked as non-counting** (dimmed, an "Auto-removed" badge, strikethrough price), so the operator sees a removed sale *in context* next to the real one it duplicated. They must **not** count toward revenue or the chart.
2. **Explain the removal reason** wherever a suppressed sale appears (the new in-list rows AND the existing dedicated surfaces): replace the static "likely brownout re-report" with the actual circumstances — *the device clock was not synced (no NTP)* and *an identical sale occurred ~N seconds earlier* — so the operator can judge whether it might actually have been a real sale.

The dedicated "Auto-removed duplicates" surfaces (PWA Device Health card + iOS Duplicates tab, with the restore action) **stay as-is** and gain the same richer reason text.

## Scope / non-goals

**In scope:** PWA + iOS. Frontend-only. Interleave suppressed rows into the Sales list; richer reason text on all suppressed surfaces; **the marked in-list rows also offer the restore action** (take up as a real sale), reusing the already-shipped `restore_suppressed_sale` RPC + each client's existing confirm flow.

**Non-goals:**
- No DB migration, no `mqtt-webhook` change, no `suppressed_sales` schema change (Approach A — derive the gap from the already-stored `matched_sale_id`).
- No new restore **backend** — the in-list restore reuses the shipped `restore_suppressed_sale(uuid)` RPC and the existing confirm flow/handler from the prior milestone; the only additions are the in-list affordance (PWA button; iOS swipe) and, on iOS, hoisting the shared confirmation dialog so both tabs can use it.
- No change to the suppression heuristic, the revenue/chart math (they keep reading real sales only), or the Nayax reconciliation view.

## Background — circumstances available at suppression time

From `mqtt-webhook` (`suppress.ts` + `index.ts`): a sale is suppressed **only** when the device payload flag `time_uncertain` is set (SNTP/clock not synced when the vend happened) **AND** a same `embedded_id`/`item_number`/`item_price`/`channel` sale exists within ±30 s (`SUPPRESS_WINDOW_MS`). The stored `suppressed_sales` row carries: `received_at` (server time the re-report arrived), `device_created_at` (raw device clock, **null** if the device clock was 0/unset), `matched_sale_id` (FK → the real `sales` row it duplicated, `ON DELETE SET NULL`), `sale_seq`, `product_id` (snapshot), and the constant `reason='time_uncertain_duplicate'`.

Two facts are therefore **derivable on the client without any backend change**:
- **Clock unsynced** — always true for a suppressed row (it's the eligibility condition). If `device_created_at` is null, the device had *no* clock at all (even more uncertain).
- **Time gap to the matched sale** — join `matched_sale_id → sales.created_at`; the gap ≈ `|received_at − matched.created_at|` (both are server-side arrival times within the 30 s window). This is the "Zeitabstand" the operator wants.

## Design

### Part 1 — Reason derivation (shared logic; applied to in-list rows AND dedicated surfaces)

Add the matched sale's `created_at` to the suppressed-rows query via the existing FK, then compute a human reason string with a small **pure, unit-tested** helper.

- **Query change** (both clients): the suppressed-sales select gains an embedded `matched_sale_id → sales(created_at)` resource.
  - PWA (`useSuppressedSales.ts`): `.select('*, products(name, image_path), matched:sales!matched_sale_id(created_at)')`. (Disambiguation hint after `!` is the `matched_sale_id` column / its FK; the plan verifies the exact hint — `suppressed_sales` has exactly one FK to `sales`.)
  - iOS (`MachineDetailViewModel.loadSuppressedSales`): add `matched:sales!matched_sale_id(created_at)` to the select string; `SuppressedSale` gains a decodable `matched` field (`{ created_at }`).
- **Reason builder** — a pure function of `(deviceCreatedAt, receivedAt, matchedCreatedAt | null)`:
  - Clock fragment: `device_created_at == null` → *"device had no clock"*; else → *"clock not synced"*.
  - Gap fragment: `matchedCreatedAt` present → *"identical sale {round(|received − matched| / 1000)}s earlier"*; else (matched sale deleted, or null) → *"near-duplicate of a recent sale"*.
  - Compose: **`"{clock} · {gap}"`** → e.g. `"Clock not synced · identical sale 3s earlier"`.
  - **Semantic note (add as a code comment):** the gap measures *server-arrival* separation (the re-report arrives after a reboot/reconnect), not necessarily the real inter-vend time. It's a plausibility signal for the operator, not an exact vend gap. Acceptable — it's the same number the suppression window judged.
  - PWA: a helper (e.g. `suppressedReasonText(row, locale)`) using i18n keys; exported/unit-tested. iOS: a `reasonText` computed on `SuppressedSale` (hardcoded English, consistent with the tab).
- **Apply everywhere a suppressed sale is shown:** the new in-list marked rows, the PWA Device Health card (replaces the static `t('machineDetail.suppressedReason')`), and the iOS `SuppressedSaleRow` (replaces the hardcoded `Text("likely brownout re-report")`).

### Part 2 — Interleave into the Sales list (visually marked, non-counting)

Reuse the **already-loaded** suppressed rows (PWA `suppressedRows`; iOS `viewModel.suppressedSales`) — no new fetch. Merge them into the Sales-list feed by timestamp; render real and suppressed rows differently; keep revenue/chart on real sales only.

**Timestamp for placement:** a suppressed row sorts/groups by its `received_at` (≈ the matched original's time, within 30 s, so it lands next to its sibling). Real sales use `created_at`.

**Marking (both clients):** dimmed/muted row, an orange **"Auto-removed"** badge, the price rendered with **strikethrough**, and the reason as a caption line. No delete, no product link. **The marked rows DO offer restore** (admin-only): PWA via a "Take up as sale" button; iOS via a swipe action (the Sales tab is converted to a `List` for this — see below). Restore reuses each client's existing confirm flow + the shipped `restore_suppressed_sale` RPC; on success the row leaves the suppressed set and the restored real sale appears, so the merged feed re-derives.

**PWA** (`app/pages/machines/[id].vue`, Sales tab):
- Evolve the `salesByDay` computed into a merged day-grouped feed: each group becomes `{ date, label, items: FeedItem[], saleCount }` where `FeedItem = { kind:'sale', sale } | { kind:'suppressed', row }`, items sorted by timestamp desc within the day. `saleCount` counts **real sales only** (the day-header "N sales" count excludes suppressed; optionally append "· M auto-removed").
- Only merge suppressed rows within the same ~30-day window as the sales query (avoid an old suppressed-only day group).
- **Day-key alignment (avoids a midnight-boundary bug):** the merged feed MUST bucket suppressed rows using the **same locale-based day key** `salesByDay` uses (`Date#toLocaleDateString(locale, …)`), **not** `toISOString().slice(0,10)` (which `salesChartData` uses and can land in a different calendar day near midnight). Reuse the `salesByDay` key path so a suppressed row sits in the same day bucket as its sibling real sale.
- Render: `v-for` over `group.items`, branch on `kind` — `sale` → the existing `SwipeToDelete` + row markup unchanged; `suppressed` → the marked variant (dimmed, badge, strikethrough price, reason caption) **plus an admin-only "Take up as sale" button** calling the page's existing `confirmRestoreSuppressed(row)`. (The confirm modal, `handleRestoreSuppressed`, and `useSuppressedSales.restore` all already exist from the prior milestone; on success the suppressed row is dropped from `suppressedRows` and `reloadSales()` brings in the restored real sale, so the merged feed updates.)
- `salesChartData` and any revenue total: **unchanged** (read `sales.value`), so suppressed never affect money.
- The realtime sales INSERT/DELETE handlers and `reloadSales()` keep mutating `sales.value` only; suppressed come from `suppressedRows` (already realtime-independent, fetched on load). The merged computed re-derives reactively from both refs.

**iOS** (`ios/VMflow/Views/Machines/MachineDetailView.swift`, Sales tab):
- Introduce a unified feed item `enum SalesFeedItem: Identifiable { case sale(Sale); case suppressed(SuppressedSale) }` exposing `date` (`sale.createdAt` / `suppressed.receivedAt`) and a **namespaced `id`** (`"sale-\(sale.id)"` / `"sup-\(suppressed.id)"`) so a (theoretical) shared UUID can't collide in `ForEach`. Add `groupFeedByDay([SalesFeedItem]) -> [FeedDayGroup]` paralleling `groupSalesByDay` (reuse `dayLabel`). Build the feed from `recentSales` + `suppressedSales`, sorted desc.
- **Define "recent" for iOS concretely** (iOS `loadSales` is `.limit(50)` with no date bound, unlike the PWA's 30-day query): include only suppressed rows whose `receivedAt >= ` the oldest visible real sale's `createdAt`, so a suppressed-only day group can't dangle below the last loaded sale.
- **Convert the Sales tab from `ScrollView { LazyVStack }` to a `List(.plain)`** (mirroring the Duplicates-tab conversion from the prior milestone) so suppressed rows can carry a native swipe. Render the unified groups as `Section`s with `DaySectionHeader` (count = real sales only): `case .sale` → the existing `SaleRow` as a List row (`.listRowBackground(.clear)`, `.listRowSeparator(.hidden)`, keep the product-sheet tap); `case .suppressed` → a marked `SuppressedSaleListRow` with an **admin-only `.swipeActions(edge: .trailing, allowsFullSwipe: false)`** green "Take up as sale" that sets `rowToRestore` + `showRestoreConfirm`.
- **Hoist the shared `.confirmationDialog`** (currently attached to `suppressedTab` from the prior milestone) up to the `TabView` in the view body, so BOTH tabs' swipes trigger the same confirm → `viewModel.restoreSuppressed(id)` → `loadDetail()`. `restoreSuppressed`, `showRestoreConfirm`, and `rowToRestore` already exist on `MachineDetailView`.
- `todayRevenue` (VM) reads `recentSales` only — unchanged.
- The dedicated **Duplicates tab is unchanged** except: `SuppressedSaleRow`’s reason line now uses `reasonText`, and its local `.confirmationDialog` moves up to the parent `TabView` (now shared with the Sales tab — its swipe still sets the same state).

### Visual marking (concrete)

- **Badge:** small orange pill, text "Auto-removed" (PWA i18n: en "Auto-removed" / de "Automatisch entfernt"; iOS hardcoded English).
- **Price:** `line-through` + muted color.
- **Row:** reduced opacity / muted foreground so it reads as inactive at a glance.
- **Caption:** the derived reason (Part 1), in a small muted/orange caption.

## Data flow

```
load → real sales (sales.value / recentSales)        ─┐
     → suppressed rows (+ matched.created_at join)    ─┤→ merged day-grouped feed (computed)
                                                        │     • real → normal row (counts, swipe/delete)
                                                        │     • suppressed → marked row (dimmed, badge,
                                                        │       strikethrough, reason caption) — NOT counted;
                                                        │       admin restore (button/swipe) → re-derives feed
revenue/chart ← real sales only (unchanged) ───────────┘
reason text ← pure builder(deviceCreatedAt, receivedAt, matched?.created_at)
```

## Backward compatibility / edge cases

- **Frontend-only + additive** — no schema/topic/payload/edge-function change; old firmware and old data unaffected.
- **Old suppressed rows / matched sale deleted** (`matched` null): reason gracefully degrades to the clock fragment + "near-duplicate of a recent sale" (no gap number). No crash.
- **Suppressed row older than the sales window:** excluded from the merged feed (window-filtered) so there's no suppressed-only day group dangling beyond the 30-day sales range. Still visible on the dedicated surface.
- **Revenue integrity:** suppressed are never added to `sales.value`/`recentSales`, so chart, totals, and `todayRevenue` are unchanged by construction.
- **Realtime:** suppressed rows are not realtime-subscribed (fetched on load, like today); a freshly suppressed sale appears in the list on next load/refresh — acceptable (matches the dedicated surface's current behavior).

## Testing

- **PWA (vitest):** unit-test the pure reason builder — clock-not-synced vs no-clock; gap rounding; matched-null fallback. Unit-test the merge/grouping helper — real+suppressed interleave by time, `saleCount` counts real only, window filter drops old suppressed. (Both are pure functions extracted for testability.)
- **iOS:** manual Xcode build/run — Sales tab shows marked, dimmed, strikethrough suppressed rows interleaved by day with the reason caption; revenue unchanged; Duplicates tab still works + shows the richer reason.
- Full `vitest run` stays green; `npm run build` clean.

## Files touched

| File | Change |
|------|--------|
| `management-frontend/app/composables/useSuppressedSales.ts` | Add `matched:sales!matched_sale_id(created_at)` to the select; `SuppressedSale` interface gains `matched`; export a pure `suppressedReasonText(row, locale)` (+ maybe a merge helper) |
| `management-frontend/app/pages/machines/[id].vue` | Merge suppressed into the Sales-tab day feed (`FeedItem`); marked non-counting row variant + admin-only restore button (reuses the prior milestone's `confirmRestoreSuppressed`/modal/`handleRestoreSuppressed`); reason caption; Device Health card reason → builder. Chart/revenue untouched |
| `management-frontend/app/composables/__tests__/useSuppressedSales.test.ts` (**extend** — already exists with `restore` tests) | Add tests for the reason builder + merge/grouping helper; keep the existing `restore` tests |
| `management-frontend/i18n/locales/en.json`, `de.json` | Keys: badge "Auto-removed", reason fragments (clock not synced / device had no clock / identical sale {n}s earlier / near-duplicate) |
| `ios/VMflow/Models/SuppressedSale.swift` | Add decodable `matched` (`{ created_at }`) + `reasonText` computed |
| `ios/VMflow/ViewModels/MachineDetailViewModel.swift` | Add `matched:sales!matched_sale_id(created_at)` to the suppressed select |
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | `SalesFeedItem` enum + `groupFeedByDay`; **convert Sales tab to `List(.plain)`** with the unified feed + marked `SuppressedSaleListRow` carrying an admin-only swipe restore; **hoist the shared `.confirmationDialog` from `suppressedTab` to the `TabView`** (both tabs); `SuppressedSaleRow` reason → `reasonText` |
