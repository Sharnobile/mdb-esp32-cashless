---
phase: 06-custom-packing-quantities
plan: 01
subsystem: ui
tags: [nuxt, vue, refill-wizard, packing, custom-quantities]

requires:
  - phase: 05-sorted-picklist
    provides: sortedMachines, combinedPickList, warehouse position sorting
provides:
  - Adjustable packing quantities per product per machine in refill wizard
  - Custom quantity state that flows through committed quantities into warehouse deductions
affects: [07-tour-history]

tech-stack:
  added: []
  patterns: [custom quantity overlay on committed quantities, displayed vs allocated quantity separation]

key-files:
  modified:
    - management-frontend/app/composables/useRefillWizard.ts
    - management-frontend/app/pages/refill/index.vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Custom quantities stored as user intent, not capped by remaining stock — recalculate handles allocation"
  - "getDisplayedPackingQty shows user's desired qty (intent), not effectiveDeficit (allocated) — prevents +/- bugs when multiple machines compete for stock"
  - "No localStorage persistence for custom quantities — only relevant during packing step"

patterns-established:
  - "Custom quantity layer: customQuantities map overrides deficit in recalculateCommittedQuantities without mutating original data"
  - "Adjuster UI uses @click.stop to prevent checkbox toggle when interacting with +/- buttons"

duration: ~15min
started: 2026-03-19T12:39:00Z
completed: 2026-03-19T12:45:00Z
---

# Phase 06 Plan 01: Custom Packing Quantities Summary

**Added adjustable packing quantities to the refill wizard — operators can now control how many of each product to pack per machine instead of committing all available warehouse stock.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~15min |
| Tasks | 2 auto + 1 checkpoint completed |
| Files modified | 4 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Custom quantity per product per machine | Pass | `[−] qty [+]` adjuster appears on checked items, defaults to max, adjustable down to 1 |
| AC-2: Warehouse stock respects custom quantities | Pass | `recalculateCommittedQuantities` uses `customQty` when set, freeing stock for other machines |
| AC-3: Combined mode reflects per-machine quantities | Pass | `effectiveDeficitCombined` sums committed quantities which now respect custom amounts; "Pro Automat anpassen" hint shown |
| AC-4: Persistence and start-tour integration | Pass | `committedQuantities` (which startTour reads) respects customQuantities; no localStorage persistence for custom amounts |

## Accomplishments

- `customQuantities` state map added to composable with `setCustomQuantity`, `getCustomQuantity`, `getMaxCustomQuantity`, `getDisplayedPackingQty` helpers
- `recalculateCommittedQuantities` now uses `Math.min(customQty, item.deficit, avail)` when custom qty is set
- Inline `[−] qty [+]` adjuster in per-machine packing checklist with `@click.stop` to prevent checkbox toggle
- Combined mode shows "Pro Automat anpassen" hint on checked items

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `management-frontend/app/composables/useRefillWizard.ts` | Modified | Added `customQuantities` state, `setCustomQuantity`, `getCustomQuantity`, `getMaxCustomQuantity`, `getDisplayedPackingQty`; modified `recalculateCommittedQuantities`, `togglePacked`, `togglePackedCombined`, `resetWizard` |
| `management-frontend/app/pages/refill/index.vue` | Modified | Added quantity adjuster UI for checked items in per-machine mode; "Adjust per machine" hint in combined mode; destructured new composable exports |
| `management-frontend/i18n/locales/en.json` | Modified | Added `refill.adjustPerMachine` key |
| `management-frontend/i18n/locales/de.json` | Modified | Added `refill.adjustPerMachine` key |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Show user intent (customQty) not allocated (effectiveDeficit) in adjuster | Prevents +/- from silently reducing intent when other machines compete for stock | Added `getDisplayedPackingQty` helper (deviation from plan) |
| No custom qty persistence in localStorage | Custom quantities only matter during the current packing session — no value in restoring stale quantities | Keeps PersistedTourState unchanged |
| Max custom qty = min(deficit, total warehouse stock) | Total stock (not remaining) because remaining shifts as other machines are checked — would be confusing | Simple, predictable upper bound |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 1 | Essential bug prevention |
| Scope additions | 0 | — |
| Deferred | 0 | — |

**Total impact:** One essential helper added to prevent a subtle UX bug.

### Auto-fixed Issues

**1. Adjuster +/- using wrong value**
- **Found during:** Task 2 code review (before UI verification)
- **Issue:** Plan specified using `effectiveDeficit` for +/- controls, but effectiveDeficit returns the *allocated* quantity (after competition with other machines), not the user's *desired* quantity. If Machine A wants 5 but only gets 3 (Machine B took the rest), pressing `+` would set customQty to 4 instead of 6.
- **Fix:** Added `getDisplayedPackingQty()` that returns customQty (user intent) when set, or effectiveDeficit as default. Adjuster operates on this value.
- **Verification:** Logic trace confirmed correct behavior in multi-machine stock competition scenarios

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| Dev DB has no machines with low stock | Could not visually test full interactive flow; verified via build + console + structural review |

## Next Phase Readiness

**Ready:**
- Phase 07 (tour-history) can proceed — custom quantities will already be reflected in `committedQuantities` which `confirmMachineRefill` uses for activity log metadata
- All composable exports are stable

**Concerns:**
- None

**Blockers:**
- None

---
*Phase: 06-custom-packing-quantities, Plan: 01*
*Completed: 2026-03-19*
