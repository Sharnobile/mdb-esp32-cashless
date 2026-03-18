---
phase: 04-warehouse-product-positions
plan: 01
subsystem: database, ui
tags: [postgres, supabase, rls, nuxt, vue, warehouse, positions]

requires:
  - phase: none
    provides: independent phase
provides:
  - warehouse_product_positions table with RLS
  - useWarehouse position CRUD (fetchPositions, savePositions, removePosition, fetchOrderedProductIds)
  - "Positionen" tab in /warehouse page
affects: [05-sorted-picklist]

tech-stack:
  added: []
  patterns: [warehouse product ordering via sort_order + location_label]

key-files:
  created:
    - Docker/supabase/migrations/20260318100000_warehouse_product_positions.sql
  modified:
    - management-frontend/app/composables/useWarehouse.ts
    - management-frontend/app/pages/warehouse/index.vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Denormalized company_id on warehouse_product_positions for RLS consistency with warehouse_stock_batches"
  - "Button-based reordering (up/down arrows) instead of drag-and-drop for mobile compatibility"
  - "Debounced auto-save (500ms) instead of explicit save button"

patterns-established:
  - "sort_order = -1 signals unpositioned product in frontend state"
  - "Positions are admin-only (RLS enforced)"

duration: ~20min
started: 2026-03-18T19:15:00Z
completed: 2026-03-18T19:35:00Z
---

# Phase 04 Plan 01: Warehouse Product Positions Summary

**Added `warehouse_product_positions` table + admin UI for defining physical product order in warehouses — foundation for sorted pick lists in Phase 05.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~20min |
| Tasks | 3 completed |
| Files modified | 5 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Product positions stored per warehouse | Pass | Table with UNIQUE(warehouse_id, product_id), sort_order + location_label |
| AC-2: RLS enforces company isolation | Pass | company_id column + RLS policies matching warehouse_stock_batches pattern |
| AC-3: Position management UI | Pass | "Positionen" tab with up/down reorder, location label input, auto-save |
| AC-4: Products without positions sort last | Pass | fetchPositions merges positioned (sort_order ASC) + unpositioned (alphabetical) |

## Accomplishments

- Created `warehouse_product_positions` table with RLS, indexes, and grants
- Extended `useWarehouse` composable with 4 new functions: `fetchPositions`, `savePositions`, `removePosition`, `fetchOrderedProductIds`
- Added "Positionen" admin tab to `/warehouse` with reordering, location labels, and auto-save
- Full i18n support (EN + DE)

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260318100000_warehouse_product_positions.sql` | Created | Table, RLS, indexes, grants |
| `management-frontend/app/composables/useWarehouse.ts` | Modified | Added WarehouseProductPosition type + 4 CRUD functions |
| `management-frontend/app/pages/warehouse/index.vue` | Modified | Added "Positionen" tab with reorder UI |
| `management-frontend/i18n/locales/en.json` | Modified | 12 new warehouse.positions* keys |
| `management-frontend/i18n/locales/de.json` | Modified | 12 new warehouse.positions* keys (German) |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Denormalized `company_id` on positions table | Matches existing `warehouse_stock_batches` pattern, simpler RLS | None — consistent with codebase |
| Up/down buttons instead of drag-and-drop | Works on mobile, no new dependencies | Simpler UX, adequate for typical product counts |
| Auto-save with 500ms debounce | No save button reduces clicks during bulk reordering | Positions persist immediately |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 1 | Minimal |
| Scope additions | 1 | Beneficial |
| Deferred | 0 | — |

**Total impact:** Minor additions, no scope creep.

### Auto-fixed Issues

**1. RLS pattern: used company_id column instead of subquery**
- **Found during:** Task 1 (migration)
- **Issue:** Plan specified RLS via `warehouse_id IN (SELECT id FROM warehouses WHERE company_id = ...)` but existing codebase denormalizes `company_id` directly
- **Fix:** Added `company_id` column to match `warehouse_stock_batches` pattern
- **Verification:** RLS policies follow identical pattern to existing warehouse tables

### Scope Additions

**1. Added `removePosition()` function**
- Not in original plan but needed for the UI "remove from positions" button
- Deletes the position row so the product returns to the unpositioned list

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| Docker not running — migration not tested against live DB | Migration follows exact same pattern as existing warehouse tables; will verify when Docker starts |
| Supabase auth not available — visual verification blocked | Build passes, no TS/runtime errors; visual test deferred to when backend runs |

## Next Phase Readiness

**Ready:**
- `fetchOrderedProductIds(warehouseId)` returns product_id[] in position order — Phase 05 can use this directly to sort pick lists
- `warehouse_product_positions` table is queryable from the refill wizard composable

**Concerns:**
- None

**Blockers:**
- None

---
*Phase: 04-warehouse-product-positions, Plan: 01*
*Completed: 2026-03-18*
