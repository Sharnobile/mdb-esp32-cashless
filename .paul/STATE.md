# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-03-17)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** AI Insights & Optimization — Phase 01: data-aggregation

## Current Position

Milestone: AI Insights & Optimization (v1.1)
Phase: 1 of 3 (data-aggregation) — Applied
Plan: 01-01 executed
Status: APPLY complete, ready for UNIFY
Last activity: 2026-03-17 — Applied Docker/supabase/migrations/20260317000000_machine_insights_rpc.sql

Progress:
- Milestone: [█░░░░░░░░░] 10%
- Phase 01: [██████████] 100% (APPLY done)

## Loop Position

Current loop state:
```
PLAN ──▶ APPLY ──▶ UNIFY
  ✓        ✓        ○     [APPLY complete, awaiting UNIFY]
```

## Accumulated Context

### Decisions
- SonarQube integration: enabled (configure via /paul:flows after planning)
- 3 phases defined: 01-data-aggregation → 02-insights-edge-function → 03-insights-ui
- RPC uses security definer + manual company_id validation (not RLS) so edge function can call it via service role
- supabase db reset pre-existing failure: companies table missing from migrations (predates migration tracking). Workaround: apply migrations directly via `docker exec supabase_db_supabase-test psql -U postgres -d postgres < <migration>`. Does not affect production deploy flow.

### Deferred Issues
- supabase db reset does not work locally (companies table never captured in migrations). Pre-existing issue, not introduced by this feature.

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-03-17
Stopped at: Plan 01-01 applied
Next action: Run /paul:unify to close loop, then plan Phase 02
Resume file: .paul/phases/01-data-aggregation/01-01-PLAN.md

---
*STATE.md — Updated after every significant action*
