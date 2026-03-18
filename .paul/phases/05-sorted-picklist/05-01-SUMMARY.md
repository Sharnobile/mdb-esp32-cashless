---
phase: 05-sorted-picklist
plan: 01
subsystem: ui
tags: [nuxt, vue, refill-wizard, picking, warehouse-positions]

requires:
  - phase: 04-warehouse-product-positions
    provides: fetchOrderedProductIds, warehouse_product_positions table
provides:
  - Position-sorted pick lists in refill wizard packing step
  - Combined picking mode (all machines in one pass)
  - Per-machine picking mode with position-sorted items
affects: []

tech-stack:
  added: []
  patterns: [computed sort layer over raw data, picking mode toggle with localStorage persistence]

key-files:
  modified:
    - management-frontend/app/composables/useRefillWizard.ts
    - management-frontend/app/pages/refill/index.vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Computed sortedMachines layer instead of mutating raw machines — keeps existing logic untouched"
  - "Combined mode caps quantities by total warehouse stock, not per-machine remaining"

patterns-established:
  - "Position order fetched in parallel with warehouse stock inside loadWarehouseStock()"
  - "Combined pick list groups by product_id across all machines"

duration: ~25min
started: 2026-03-18T19:35:00Z
completed: 2026-03-18T20:00:00Z
---

# Phase 05 Plan 01: Sorted Pick List Summary

**Added position-sorted pick lists and combined picking mode to the refill wizard — operators can now walk through the warehouse linearly in a single pass.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~25min |
| Tasks | 2 completed |
| Files modified | 4 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Pick list sorted by warehouse position | Pass | `sortedMachines` computed sorts tray_summary by warehouseProductOrder |
| AC-2: Combined picking mode | Pass | `combinedPickList` merges all machines, sorted by position, quantities capped by warehouse stock |
| AC-3: Per-machine picking mode (default) | Pass | Existing card layout using `sortedMachines` instead of raw `machines` |
| AC-4: Mode toggle persists during tour | Pass | `pickingMode` saved/restored in PersistedTourState via localStorage |

## Accomplishments

- Position-based sorting integrated into `loadWarehouseStock()` via parallel query
- Combined picking mode merges all machines' products into one flat position-sorted list
- Mode toggle ("Pro Automat" / "Alle zusammen") with correct active state styling
- Combined mode quantity calculation correctly caps totals by warehouse stock

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `management-frontend/app/composables/useRefillWizard.ts` | Modified | Added PickingMode, CombinedPickItem types; pickingMode + warehouseProductOrder state; sortedMachines + combinedPickList + allPackedCombined computeds; togglePackedCombined, isPackedCombined, effectiveDeficitCombined helpers; persistence |
| `management-frontend/app/pages/refill/index.vue` | Modified | Mode toggle UI, combined pick list view, switched per-machine cards to sortedMachines |
| `management-frontend/i18n/locales/en.json` | Modified | 4 new refill.* keys |
| `management-frontend/i18n/locales/de.json` | Modified | 4 new refill.* keys (German) |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Computed sort layer over raw machines | Keeps initTour/startTour/recalculateCommittedQuantities untouched — zero risk to existing logic | Clean separation |
| Position fetch in parallel with stock fetch | Single network round-trip, no extra loading state | No performance impact |
| Combined deficit capped by warehouse total | User reported bug: naive sum showed 16 when only 10 in stock | Correct UX |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 1 | Essential bug fix |
| Scope additions | 0 | — |
| Deferred | 0 | — |

**Total impact:** One essential fix during verification.

### Auto-fixed Issues

**1. Combined mode quantity calculation bug**
- **Found during:** Visual verification of combined mode
- **Issue:** `effectiveDeficitCombined` summed per-machine `effectiveDeficit` independently — each machine saw full warehouse stock remaining, producing inflated totals (e.g. 16 shown when only 10 in stock)
- **Fix:** Changed to calculate `min(totalDeficit, warehouseTotal)` for unchecked items, sum committed quantities for checked items
- **Verification:** Visually confirmed "10x Haribo Pico Bala" (correctly capped from 8+8=16 to 10)

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| Hydration mismatches in console | Pre-existing SSR issue (auth middleware skips org fetch on SSR) — not related to our changes |

## Next Phase Readiness

**Ready:**
- Milestone v1.2 (Warehouse Picking Optimization) is complete
- Both phases delivered: product positions (Phase 04) + sorted pick lists (Phase 05)

**Concerns:**
- None

**Blockers:**
- None

---
*Phase: 05-sorted-picklist, Plan: 01*
*Completed: 2026-03-18*
