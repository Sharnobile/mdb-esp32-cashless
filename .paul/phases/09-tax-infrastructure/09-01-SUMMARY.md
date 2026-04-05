---
phase: 09-tax-infrastructure
plan: 01
subsystem: database
tags: [postgres, tax, vat, rls, trigger, migration]

requires: []
provides:
  - tax_classes and tax_rates tables with RLS
  - system_tax_rates reference table with 29 EU rates
  - tax columns on sales (tax_rate_snapshot, tax_amount, price_net)
  - country_code on companies and vendingMachine
  - tax_class_id on product_category and products
  - updated stamp trigger with automatic tax calculation
affects: [09-02 (UI), 10 (backfill), 11 (export)]

tech-stack:
  added: []
  patterns: [COALESCE chain for country resolution, temporal tax rate lookup with valid_from/valid_to]

key-files:
  created:
    - Docker/supabase/migrations/20260406000000_tax_infrastructure.sql
    - Docker/supabase/migrations/20260406100000_seed_system_tax_rates.sql
  modified: []

key-decisions:
  - "Tax stamping in DB trigger, not edge functions — single source of truth"
  - "Graceful fallback: missing tax config leaves NULL, never blocks sale"
  - "NUMERIC(6,4) for rates, NUMERIC(10,4) for amounts — precision over float"

patterns-established:
  - "Tax lookup chain: machine→country + product→tax_class → tax_rates"
  - "COALESCE(vendingMachine.country_code, companies.country_code, 'DE') for country resolution"
  - "system_tax_rates as read-only reference, copied to company tables via frontend"

duration: 10min
started: 2026-04-05
completed: 2026-04-05
---

# Phase 09 Plan 01: Tax Infrastructure DB Migration

**Complete tax database layer: 3 new tables, 7 new columns, updated sales trigger with automatic tax stamping, and 29 EU reference rates across 13 countries.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~10min |
| Tasks | 2 completed |
| Files created | 2 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Tax classes table with RLS | Pass | 4 policies (SELECT/INSERT/UPDATE/DELETE) using my_company_id() |
| AC-2: Tax rates table with temporal validity | Pass | UNIQUE on (company_id, tax_class_id, country_code, valid_from) |
| AC-3: System reference rates seeded | Pass | 29 rows across 13 countries (DE, AT, CH, FR, IT, ES, NL, BE, PL, CZ, PT, LU) |
| AC-4: Existing tables have new nullable columns | Pass | All nullable or with safe defaults (country_code DEFAULT 'DE') |
| AC-5: Sales trigger stamps tax data | Pass | Resolves country→tax_class→rate, calculates price_net and tax_amount |
| AC-6: Trigger handles missing config gracefully | Pass | All tax columns remain NULL if no config found, sale never blocked |

## Accomplishments

- Complete tax infrastructure with `tax_classes`, `tax_rates`, `system_tax_rates` tables and full RLS
- Updated `stamp_machine_and_decrement_stock` trigger: resolves country via COALESCE chain, looks up tax class via product→category fallback, stamps rate + net price + tax amount
- 29 EU reference rates seeded for 13 countries with temporal validity support
- Fully backward-compatible: all new columns nullable, trigger gracefully handles missing config

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260406000000_tax_infrastructure.sql` | Created | Tables, columns, RLS, trigger update |
| `Docker/supabase/migrations/20260406100000_seed_system_tax_rates.sql` | Created | 29 EU reference rates for 13 countries |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Tax stamping in trigger, not edge functions | Single source of truth for both MQTT and manual sales | No edge function changes needed |
| Graceful NULL fallback | Backward compatibility — existing sales flow unchanged | Phase 10 backfill will fill historical NULLs |
| NUMERIC precision types | Avoid float rounding in tax calculations | Reliable summation for DATEV export |

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## Next Phase Readiness

**Ready:**
- DB layer complete for Plan 09-02 (frontend UI)
- Tax classes and rates can be CRUDed via Supabase client
- system_tax_rates available for seeding company rates

**Concerns:**
- None

**Blockers:**
- None

---
*Phase: 09-tax-infrastructure, Plan: 01*
*Completed: 2026-04-05*
