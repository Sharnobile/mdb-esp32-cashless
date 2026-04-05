---
phase: 10-tax-backfill-validation
plan: 01
subsystem: database, ui
tags: [postgres, rpc, backfill, validation, nuxt, vue]

requires:
  - phase: 09-tax-infrastructure
    provides: tax_classes, tax_rates tables, sales tax columns, useTaxSettings composable
provides:
  - backfill_sales_tax() RPC function
  - Backfill button on Settings page
  - Tax class warning banner on Products page
  - taxReadiness computed for export blocker (Phase 11)
affects: [11 (tax-reports-export)]

tech-stack:
  added: []
  patterns: [DISTINCT ON for newest-rate-per-sale in backfill query]

key-files:
  created:
    - Docker/supabase/migrations/20260406200000_tax_backfill_function.sql
  modified:
    - management-frontend/app/composables/useTaxSettings.ts
    - management-frontend/app/pages/settings/index.vue
    - management-frontend/app/pages/products/index.vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "DISTINCT ON (s2.id) ORDER BY tr.valid_from DESC picks newest valid rate per sale"
  - "my_company_id() check in RPC for authorization"
  - "Warning banner uses v-if='!loading' instead of v-else to avoid template nesting issues"

patterns-established:
  - "taxReadiness computed: { categoriesWithoutTax, isReady } for export gating"
  - "categoriesWithoutTax derives from useProducts() categories state"

duration: 15min
started: 2026-04-05
completed: 2026-04-05
---

# Phase 10 Plan 01: Tax Backfill & Validation

**Database backfill function for historical sales tax stamping, admin backfill UI, and category tax-class validation warnings.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~15min |
| Tasks | 1 completed |
| Files created | 1 |
| Files modified | 5 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Backfill function stamps historical sales | Pass | DISTINCT ON + ORDER BY valid_from DESC picks newest rate |
| AC-2: Backfill button in Settings UI | Pass | Shows count result or "nothing to update" |
| AC-3: Validation detects unconfigured categories | Pass | Amber warning banner on Products page |
| AC-4: Tax readiness check for export | Pass | taxReadiness computed with categoriesWithoutTax + isReady |

## Accomplishments

- `backfill_sales_tax(p_company_id)` RPC: joins sales→machine→trays→products→category→tax_rates, uses DISTINCT ON for newest valid rate, returns update count
- Backfill button on Settings page with loading state and result message
- Warning banner on Products page when categories lack tax class assignments
- `taxReadiness` and `categoriesWithoutTax` computed properties in useTaxSettings for Phase 11 export gating

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260406200000_tax_backfill_function.sql` | Created | backfill_sales_tax RPC |
| `app/composables/useTaxSettings.ts` | Modified | backfillSales(), categoriesWithoutTax, taxReadiness |
| `app/pages/settings/index.vue` | Modified | Backfill button + result display |
| `app/pages/products/index.vue` | Modified | Tax class warning banner |
| `i18n/locales/en.json` | Modified | Backfill + banner i18n keys |
| `i18n/locales/de.json` | Modified | Same keys in German |

## Deviations from Plan

### Auto-fixed Issues

**1. Template nesting error with v-else wrapper**
- **Found during:** Task 1 verification
- **Issue:** Wrapping Tabs in `<div v-else>` caused Vue compiler "missing end tag" error due to pre-existing tag imbalance
- **Fix:** Used independent `v-if="!loading"` conditions on banner and Tabs instead of v-else wrapper
- **Files:** `products/index.vue`

## Issues Encountered

None beyond the template fix above.

## Next Phase Readiness

**Ready:**
- Phase 10 complete — backfill + validation in place
- `taxReadiness.isReady` available for export page blocker (Phase 11)
- All tax infrastructure (DB + UI + backfill) complete

**Concerns:**
- None

**Blockers:**
- None

---
*Phase: 10-tax-backfill-validation, Plan: 01*
*Completed: 2026-04-05*
