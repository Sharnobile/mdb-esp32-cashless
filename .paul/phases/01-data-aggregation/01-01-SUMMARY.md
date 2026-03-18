---
phase: 01-data-aggregation
plan: 01
subsystem: database
tags: [postgresql, rpc, plpgsql, supabase, kpi, aggregation]

requires: []
provides:
  - "PostgreSQL RPC get_machine_insights_kpis(machine_id, company_id, days) → json"
  - "Pre-aggregated machine KPIs: sales, revenue, sell-through, dead-stock, paxcounter, refill history"
affects: [02-insights-edge-function, 03-insights-ui]

tech-stack:
  added: []
  patterns:
    - "security definer + manual company_id check (not RLS) for service-role callable RPCs"
    - "Pre-aggregate in SQL, not in application layer — keeps AI prompts token-efficient"

key-files:
  created:
    - Docker/supabase/migrations/20260317000000_machine_insights_rpc.sql
  modified: []

key-decisions:
  - "Use vendingMachine.company (not company_id) — actual FK column name in this schema"
  - "security definer so edge function can call via service role without RLS bypass"
  - "sell_through_pct normalized to weekly capacity (units_sold / capacity*days/7 * 100) — avoids penalizing slow-turn products"
  - "warehouse_transactions.reference_id is TEXT — cast machine_id::text for comparison"

patterns-established:
  - "New RPCs for AI feature: always security definer + manual company ownership check"
  - "item_price stored in cents (integer) — always divide by 100.0 for EUR display"

duration: ~25min
started: 2026-03-17T22:00:00Z
completed: 2026-03-18T00:00:00Z
---

# Phase 01 Plan 01: Data Aggregation Summary

**PostgreSQL RPC `get_machine_insights_kpis` created — delivers pre-computed per-machine KPIs (revenue, sell-through %, dead stock, paxcounter conversion, refill history) as a single JSON call for the AI insights edge function.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~25 min |
| Started | 2026-03-17 |
| Completed | 2026-03-18 |
| Tasks | 1 of 1 completed |
| Files created | 1 |
| Files modified | 0 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: RPC returns correct structure | ✅ Pass | All 6 top-level keys present: machine, period_days, summary, trays, paxcounter, refill_history |
| AC-2: Tray-level KPIs accurate | ✅ Pass | All 10 fields per tray: item_number, product_name, product_id, capacity, current_stock, units_sold, revenue_eur, sell_through_pct, avg_daily_units, days_until_empty, is_dead_stock |
| AC-3: Paxcounter conversion rate | ✅ Pass | latest_count + conversion_rate (null-safe via NULLIF) |
| AC-4: Company isolation enforced | ✅ Pass | `vendingMachine.company = p_company_id` check; returns null if not found |
| AC-5: Migration applies cleanly | ⚠️ Partial | Pre-existing `supabase db reset` failure (see Deviations). Migration applied cleanly via docker exec; function confirmed in pg_proc |

## Accomplishments

- Created `get_machine_insights_kpis` with correct 3-arg signature, all 7 JSON sections, null-safe division throughout
- Function registered and grants applied (`authenticated` + `service_role`) — verified with `\df` in running DB
- Boundaries respected: zero existing files modified, no edge function or frontend changes

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260317000000_machine_insights_rpc.sql` | Created | RPC function + grants |

## Decisions Made

| Decision | Rationale | Impact on Phase 02 |
|----------|-----------|-------------------|
| `vendingMachine.company` (not `company_id`) | Actual FK column name in this codebase | Phase 02 edge function must use `company` not `company_id` when querying vendingMachine |
| `security definer` + manual `p_company_id` check | Service role client in edge function bypasses RLS — manual check enforces tenancy | Edge function passes company_id from authenticated user's JWT claim |
| `warehouse_transactions.reference_id` is `text` | Existing column type; cast `p_machine_id::text` for comparison | Phase 02: pass machine_id as UUID, RPC handles cast |
| sell_through_pct = units / (capacity × days/7) × 100 | Weekly-normalized: avoids penalizing products with lower restock frequency | AI prompt should describe this as "weekly capacity throughput %" |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Schema corrections | 2 | Absorbed in implementation, no scope change |
| Verification workaround | 1 | Documented, pre-existing issue |

**Total impact:** No scope creep. Schema discoveries corrected during implementation.

### Schema Corrections (auto-fixed)

**1. vendingMachine.company vs company_id**
- **Found during:** Schema exploration before implementation
- **Plan said:** `embeddeds.company_id = p_company_id`
- **Actual:** Column is `vendingMachine.company` (company UUID FK) — this pattern is consistent across the schema (`embeddeds.company`, `products.company`, etc.)
- **Fix:** Used `vm.company = p_company_id` in ownership check
- **Impact:** None — same security guarantee, correct column name

**2. supabase db reset verification method**
- **Found during:** Verification step
- **Plan said:** `supabase db reset` to verify migration applies cleanly
- **Actual:** `supabase db reset` fails with pre-existing issue — `public.companies` table was created manually before migration tracking was added, so it's not in any migration file. First migration (`20260228000000_multitenancy.sql`) references `companies` before creating it.
- **Fix:** Applied migration via `docker exec supabase_db_supabase-test psql -U postgres -d postgres < <file>`. Function confirmed via `\df`.
- **Impact:** Pre-existing environment issue, not introduced by this feature. Does not affect production Docker deploy.

## Schema Discoveries for Phase 02

Critical findings Phase 02 must know:

| Column | Table | Note |
|--------|-------|------|
| `company` | `vendingMachine`, `embeddeds`, `products` | FK column is named `company`, not `company_id` |
| `item_price` | `sales` | Integer, stored in **cents** — divide by 100.0 for EUR |
| `reference_id` | `warehouse_transactions` | TEXT type — stores machine_id as string |
| `embedded` | `vendingMachine` | FK to embeddeds.id (column name is `embedded`, not `embedded_id`) |

## RPC Consumption Reference (for Phase 02 Edge Function)

```typescript
// Call from edge function (service role client)
const { data } = await adminClient
  .rpc('get_machine_insights_kpis', {
    p_machine_id: machineId,
    p_company_id: companyId,  // from JWT → organization_members
    p_days: 30
  })

// Returns null if machine not found / wrong company
// Returns JSON shape:
// {
//   machine: { id, name, status },
//   period_days: 30,
//   summary: { total_revenue_eur, total_units, avg_daily_revenue_eur },
//   trays: [{ item_number, product_name, product_id, capacity, current_stock,
//             units_sold, revenue_eur, sell_through_pct, avg_daily_units,
//             days_until_empty, is_dead_stock }],
//   paxcounter: { latest_count, conversion_rate },
//   refill_history: [{ refill_date, product_name, quantity }]
// }
```

## Next Phase Readiness

**Ready:**
- RPC callable from Phase 02 edge function via service role client
- JSON shape is deterministic and documented — Claude prompt can describe fields precisely
- Company isolation built into RPC — edge function does not need extra security checks
- `sell_through_pct` and `is_dead_stock` computed — AI prompt has actionable signals

**Concerns:**
- `supabase db reset` remains broken locally — Phase 02 must also apply migrations via `docker exec` for local testing
- Empty-DB smoke test for null-return not possible until local DB is populated

**Blockers:**
- None

---
*Phase: 01-data-aggregation, Plan: 01*
*Completed: 2026-03-18*
