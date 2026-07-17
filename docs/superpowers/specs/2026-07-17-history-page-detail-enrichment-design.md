# History page detail enrichment — design

Date: 2026-07-17
Status: approved (brainstorming), pending implementation plan

## Problem

The `/history` page (`management-frontend/app/pages/history/index.vue`) renders
`activity_log` rows via a shared descriptor
(`management-frontend/app/lib/activityDescriptor.ts`), reused by the dashboard
activity feed. Two entry types are missing information an operator needs:

1. **`sale_recorded`** (a real MDB sale reported by firmware over MQTT) shows
   only machine, slot #, price, and payment channel — no product name or
   image. Root cause: `mqtt-webhook/index.ts` already resolves
   `productName`/`productImageUrl`/`tray.product_id` for the sale push
   notification, but never copies them into the `activity_log.metadata` it
   writes right after — the metadata object is built from separate local
   variables (`itemNumber`, `salePrice`, `channel`) instead of reusing what
   was just looked up.
2. **`stock_refill_tour`** (a tour-wizard refill of one machine) shows a tray
   count and a total, but the per-product breakdown renders as bare `×N`
   numbers with no product name attached, because
   `history/index.vue`'s chip template only ever renders `chip.value` —
   `chip.label` (which is where the product name currently lives for this
   action) is never displayed. `stock_refill_all` ("Alle Fächer auffüllen")
   has the exact same bug, for the same reason, since it uses the same
   label-carries-the-name chip pattern.

There is also no debugging trail for the known duplicate-sale issue (see
`sale_seq` / `time_uncertain` on the `sales` table, tracked in project memory
as "duplicate sales root cause") — none of that reaches `activity_log`.

## Goals

- `sale_recorded` rows show the product thumbnail + name, same as the other
  sale actions (`sale_deleted`, `sale_inserted`, `sale_restored`).
- `stock_refill_tour` and `stock_refill_all` rows show what was *actually*
  refilled: product thumbnail, name, and old→new stock per item — not just a
  quantity.
- Rows with more detail than fits on one line get an expand affordance
  (chevron / click-to-expand) that reveals the full item list.
- A "technical details" panel, revealed the same way, surfaces
  operator-useful debugging fields not otherwise shown — starting with
  `sale_seq` and a `time_uncertain` warning on `sale_recorded`, so an
  operator can tell whether a sale that looks duplicated was a genuine repeat
  purchase or a firmware double-report.
- Visible to all users with `/history` access — no new role gate.

## Non-goals

- **No retroactive backfill.** Historical `activity_log` rows written before
  this change keep whatever metadata they already have (no product image on
  old `sale_recorded` rows). This matches how the rest of the descriptor
  already behaves — chips/thumbnails only render when the underlying
  metadata key is present. Joining historical rows back to `sales`/`products`
  at render time was considered and rejected: `activity_log.entity_id` for
  `sale_recorded` is the device id, not the sale id, so there's no clean FK;
  a fuzzy match on device + item_number + price + timestamp window adds
  real complexity and mismatch risk for a one-time historical gap.
- **No DB schema change / migration.** All new fields are additive keys in
  the existing `jsonb metadata` column, written by application code that
  already runs (the webhook's activity_log insert, the refill wizard's
  activity_log insert). Nothing here touches a table definition.
- **No role gating** for the technical-details panel.
- Not attempting to surface literally every system event in this pass (full
  "debugging interface" is a direction, not a checklist) — scoped to the two
  concrete gaps named above plus the sale-dedup fields, with the
  `activityDetails()` function shaped so more fields/actions can be added
  later without restructuring.

## Design

### 1. Backend: `Docker/supabase/functions/mqtt-webhook/index.ts`

The sale-handling branch already resolves, for the push notification:
`productName`, `productImageUrl`, and `tray` (which has `product_id`), plus
already has `saleSeq` and `timeUncertain` in scope from the dedup logic above
it. Extend the existing best-effort `activity_log` insert (~line 620) to add:

```ts
metadata: {
  item_number: itemNumber,
  price: salePrice,
  channel,
  device_id: embedded.id,
  product_id: tray?.product_id ?? null,
  product_name: productName ?? null,
  sale_seq: saleSeq,
  time_uncertain: timeUncertain,
}
```

`tray`/`productName` are already `null`/`undefined`-safe from the existing
lookup above (a sale on a slot with no assigned product, or a machine record
that fails to resolve, falls through to `null` — same as today, just also
persisted). `saleSeq` is `number | null`; `activityDetails` (below) must
render on presence (`sale_seq != null`), not truthiness, since `0` is a
valid sequence number.

No other change to this function. Still wrapped in the existing try/catch —
a logging failure must never affect the sale itself.

### 2. Frontend: `management-frontend/app/composables/useRefillWizard.ts`

`confirmMachineRefill()` already has `results` (RPC response: `tray_id`,
`old_stock`, `new_stock` per tray) and `traysToRefill` (`id`, `item_number`,
`product_id`, `product_name`, `fill_amount`) in scope. Build a snapshot
mirroring `useMachineTrays.ts`'s `stock_refill_all` shape:

```ts
const snapshot = results.map(r => {
  const tray = traysToRefill.find(t => t.id === r.tray_id)
  return {
    id: r.tray_id,
    item_number: tray?.item_number,
    product_name: tray?.product_name,
    product_id: tray?.product_id,
    old_stock: r.old_stock,
    new_stock: r.new_stock,
  }
})
```

Replace the metadata's `trays_refilled: results.length` with
`trays_refilled: snapshot`, and drop the separate flat `products` array (the
snapshot is a strict superset — it carries quantity implicitly via
`new_stock - old_stock`, which is also more correct: it reflects what the
RPC actually applied after any capacity clamp, not just what was requested).
`total_added` stays as-is (already computed from `results`).

`activityDescriptor.ts`'s existing fallback (`Array.isArray(m.trays_refilled)
? m.trays_refilled.length : m.trays_refilled`) already tolerates both the old
plain-number shape and the new array shape, so this is backward compatible
with historical rows.

### 3. Descriptor: `management-frontend/app/lib/activityDescriptor.ts`

- **`activityProductRef`**: add a `sale_recorded` case reading
  `product_id`/`product_name` from metadata, same pattern as
  `sale_deleted`/`sale_inserted`/`sale_restored`/`stock_updated`.

- **New `activityProductRefs(entry): ProductRefWithStock[]`** — plural
  variant for multi-item entries. Reads `trays_refilled` when it's an array,
  for both `stock_refill_all` and `stock_refill_tour`, returning
  `{ productId, productName, oldStock, newStock }[]`, falling back to
  `#item_number` for `productName` when a tray has no assigned product
  (mirrors the existing `stock_refill_all` chip fallback in
  `activityChips` today). This replaces the current per-product chip loops
  in both actions' `activityChips` cases for the **array** `trays_refilled`
  shape — those loops stay removed for that shape.

  For `stock_refill_tour` specifically, historical rows written before this
  change have neither an array `trays_refilled` nor per-item stock deltas —
  only the old flat `products: [{product_id, product_name, quantity}]`
  array (no images, no old/new stock). `activityProductRefs` must also
  accept that legacy shape as a fallback source (mapped to
  `{ productId, productName, oldStock: undefined, newStock: undefined,
  quantity }`, with the view rendering `×quantity` instead of an old→new
  pill when stock deltas are absent) — otherwise those rows regress from
  "broken but present" `×N` chips today to nothing at all, which the
  non-goals section explicitly rules out.

- **New `activityDetails(entry): ActivityDetail[]`** — curated
  "technical details" for the expand panel, deliberately a whitelist (not a
  raw metadata dump, to avoid leaking noise like internal `_user_email`
  fields already used for other purposes). Initial cases:
  - `sale_recorded`: `sale_seq` (if present) as a plain detail row;
    `time_uncertain === true` as a `warning`-variant detail row with a
    translated explanation string.
  - Everything else: `[]` (no panel shown).

- Update `ActivityChip`/new types as needed; keep everything pure/unit
  testable per the file's existing convention (no Nuxt/i18n runtime
  dependency, `t`/formatters injected via `DescriptorCtx`).

### 4. Composable: `useActivityDescriptor.ts`

Expose `activityProductRefs` and `activityDetails` bound to the same
injected context (`machineName`, `machineNameByDevice`, `t`), alongside the
existing `actionLabel`/`actionIcon`/`metadataChips`/`productRef`.

### 5. UI: `management-frontend/app/pages/history/index.vue`

- Add an `expandedIds: Set<string>` (or similar) piece of state; a
  chevron button appears on a row only when there's something to expand —
  i.e. `activityProductRefs(entry).length > 3` (show first 3 inline, "+N
  more" summary) **or** `activityDetails(entry).length > 0`.
- Render `activityProductRefs()` results as a small list of
  thumbnail + name + old→new-stock pills (visually similar to the existing
  single-`productRef` treatment, reusing `resolveProductImage()`).
- Expanded panel: full product list (all items, not just the first 3) +
  a "Technical details" section listing `activityDetails()` rows, the
  `time_uncertain` warning styled distinctly (e.g. amber/warning tint,
  matching the existing `TINT_CLASSES` palette).
- `sale_recorded` picks up the product thumbnail via the now-extended
  `productRef()` — no template change needed beyond what already renders
  `productRef(entry)` (history/index.vue:251-265 already does this
  generically for any action `activityProductRef` returns non-null for).

### 6. i18n (`management-frontend/i18n/locales/{de,en}.json`)

New keys under `activity` / `activity.field`, e.g.:
`activity.technicalDetails`, `activity.field.saleSeq`,
`activity.timeUncertainWarning`, `activity.showMore` / `activity.showLess`,
`activity.moreItems` (interpolated with a count).

### 7. Testing

- `app/lib/__tests__/activityDescriptor.test.ts`: add cases for
  `activityProductRef('sale_recorded', ...)`,
  `activityProductRefs` on both `stock_refill_all`/`stock_refill_tour`
  (array and legacy-number `trays_refilled` shapes), and `activityDetails`
  for `sale_recorded` with/without `time_uncertain`.
- No new edge-function test required beyond existing coverage; the webhook
  change is a pure additive metadata write with no new branch/error path
  worth a dedicated Deno test, consistent with the existing best-effort
  try/catch around this insert.
- Manual verification: trigger a real (or simulated) sale and a tour refill
  against local Supabase, confirm the enriched rows render correctly with
  images and expand panels, and confirm historical rows (pre-change) still
  render without errors (missing-field tolerance).

## Files touched

- `Docker/supabase/functions/mqtt-webhook/index.ts`
- `management-frontend/app/composables/useRefillWizard.ts`
- `management-frontend/app/lib/activityDescriptor.ts`
- `management-frontend/app/composables/useActivityDescriptor.ts`
- `management-frontend/app/pages/history/index.vue`
- `management-frontend/i18n/locales/de.json`, `en.json`
- `management-frontend/app/lib/__tests__/activityDescriptor.test.ts`
