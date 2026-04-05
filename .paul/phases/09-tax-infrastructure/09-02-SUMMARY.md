---
phase: 09-tax-infrastructure
plan: 02
subsystem: ui
tags: [nuxt, vue, composable, i18n, supabase, edge-function]

requires:
  - phase: 09-tax-infrastructure plan 01
    provides: tax_classes, tax_rates, system_tax_rates tables + sales trigger
provides:
  - useTaxSettings composable for tax class/rate CRUD
  - Tax Settings section on Settings page (admin-only)
  - Tax class assignment on product categories
  - Country selector on machine detail page
  - Auto-seed of DE tax classes on organization creation
affects: [10 (backfill validation UI), 11 (export page)]

tech-stack:
  added: []
  patterns: [composable for tax CRUD with getCurrentRate helper, COUNTRY_OPTIONS constant]

key-files:
  created:
    - management-frontend/app/composables/useTaxSettings.ts
  modified:
    - management-frontend/app/pages/settings/index.vue
    - management-frontend/app/pages/products/index.vue
    - management-frontend/app/composables/useProducts.ts
    - management-frontend/app/pages/machines/[id].vue
    - management-frontend/app/composables/useMachines.ts
    - Docker/supabase/functions/create-organization/index.ts
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "getCurrentRate sorts by valid_from DESC to pick newest valid rate"
  - "Tax rate modal includes optional valid_to for temporal rate changes"
  - "Country selector on machine uses empty string for 'inherit from company'"

patterns-established:
  - "COUNTRY_OPTIONS exported as const array from useTaxSettings for reuse"
  - "formatTaxClassLabel() pattern: 'Standard (19%)' for dropdowns"
  - "Category edit via updateCategory() — new function added to useProducts"

duration: 25min
started: 2026-04-05
completed: 2026-04-05
---

# Phase 09 Plan 02: Tax Infrastructure Frontend UI

**Complete tax management UI: Settings page with tax class/rate CRUD, category tax class assignment, machine country selector, and auto-seeded DE rates on organization creation.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~25min |
| Tasks | 3 completed (2 auto + 1 checkpoint) |
| Files created | 1 |
| Files modified | 8 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Tax settings UI on Settings page | Pass | Country dropdown, tax classes CRUD, rates per class, seed button |
| AC-2: Tax class assignment on categories | Pass | Dropdown in category modal, column in table with warning for unassigned |
| AC-3: Country selector on machines | Pass | Below machine name, inherits from company when empty |
| AC-4: Auto-seed on org creation | Pass | create-organization seeds standard + reduced classes with DE rates |
| AC-5: i18n support | Pass | All keys in EN + DE |

## Accomplishments

- `useTaxSettings` composable with full CRUD, `seedFromSystem()`, `getCurrentRate()` (newest-first), `formatTaxClassLabel()`
- Tax Settings section on Settings page: company country, tax classes with expandable rates, seed defaults button
- Category form with tax class dropdown showing rate percentage, table with warning for unassigned categories
- Machine detail country selector with company-default fallback display
- `create-organization` edge function seeds "standard" (19%) + "reduced" (7%) DE tax classes/rates

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `app/composables/useTaxSettings.ts` | Created | Tax class/rate CRUD, system rates, country management |
| `app/pages/settings/index.vue` | Modified | Tax Settings section (admin-only) with modals |
| `app/pages/products/index.vue` | Modified | Tax class column on categories, edit button, dropdown in modal |
| `app/composables/useProducts.ts` | Modified | tax_class_id on ProductCategory, updateCategory() |
| `app/pages/machines/[id].vue` | Modified | Country selector, updateMachineCountry() |
| `app/composables/useMachines.ts` | Modified | country_code on VendingMachine interface + select |
| `create-organization/index.ts` | Modified | Seed tax classes + rates after company creation |
| `i18n/locales/en.json` | Modified | Tax settings, products, machines i18n keys |
| `i18n/locales/de.json` | Modified | Same keys in German |

## Deviations from Plan

### Auto-fixed Issues

**1. getCurrentRate() returned wrong rate for multiple entries**
- **Found during:** Checkpoint (human-verify)
- **Issue:** `find()` returned first match, not newest valid rate
- **Fix:** Changed to `filter()` + `sort()` by `valid_from DESC`, pick `[0]`
- **Files:** `useTaxSettings.ts`

**2. Missing valid_to field on tax rate modal**
- **Found during:** Checkpoint (human-verify)
- **Issue:** No way to set end date for tax rates
- **Fix:** Added optional `validTo` to form + `createTaxRate()` parameter + date input in modal
- **Files:** `useTaxSettings.ts`, `settings/index.vue`

## Issues Encountered

None beyond the checkpoint fixes above.

## Next Phase Readiness

**Ready:**
- Phase 09 complete — tax infrastructure DB + UI fully in place
- Phase 10 (backfill + validation) can build on tax_classes, tax_rates, sales columns
- Phase 11 (export) can use getCurrentRate() and tax data on sales

**Concerns:**
- None

**Blockers:**
- None

---
*Phase: 09-tax-infrastructure, Plan: 02*
*Completed: 2026-04-05*
