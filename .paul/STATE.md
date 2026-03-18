# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-03-18)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Milestone v1.2 complete — no active work

## Current Position

Milestone: Warehouse Picking Optimization (v1.2) — Complete
Phase: 2 of 2 complete
Plan: All plans complete
Status: Milestone complete
Last activity: 2026-03-18 — Phase 05 complete, milestone v1.2 closed

Progress:
- Milestone v1.2: [██████████] 100%

## Loop Position

Current loop state:
```
PLAN ──▶ APPLY ──▶ UNIFY
  ✓        ✓        ✓     [Loop complete — milestone finished]
```

## Accumulated Context

### Decisions
- `warehouse_product_positions` table: per-warehouse, per-product sort_order + optional location_label
- Denormalized `company_id` on positions table for RLS consistency
- Button-based reordering (up/down arrows) for mobile compatibility
- Computed sort layer over raw machines (sortedMachines) — zero risk to existing logic
- Combined deficit capped by warehouse total stock, not per-machine remaining
- Position fetch in parallel with stock fetch inside loadWarehouseStock()

### Git State
Last commit: 988caed
Branch: main

### Paused Work
- AI Insights v1.1: Phase 02 applied (UNIFY pending), Phase 03 not started
- Resume with: /paul:unify .paul/phases/02-insights-edge-function/02-01-PLAN.md

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue.
- Phase 04 migration not yet applied to production DB (needs Docker restart)

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-03-18
Stopped at: Milestone v1.2 complete
Next action: Start next milestone, resume AI Insights (v1.1), or pause
Resume file: .paul/ROADMAP.md

---
*STATE.md — Updated after every significant action*
