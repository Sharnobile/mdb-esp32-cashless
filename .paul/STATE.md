# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-04-05)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Steuer-Berichte — tax backfill and export validation

## Current Position

Milestone: Steuer-Berichte (v1.5)
Phase: 10 of 11 (tax-backfill-validation) — Ready to plan
Plan: Not started
Status: Phase 09 complete, ready to plan Phase 10
Last activity: 2026-04-05 — Phase 09 complete, transitioned to Phase 10

Progress:
- Steuer-Berichte v1.5: [███░░░░░░░] 33%
- Phase 09: [██████████] 100%
- Phase 10: [░░░░░░░░░░] 0%

## Loop Position

Current loop state:
```
PLAN ──▶ APPLY ──▶ UNIFY
  ○        ○        ○     [Ready for first PLAN]
```

## Accumulated Context

### Decisions
- Tax classes + tax rates table (not simple field on category) — future-proof for multi-country
- System-wide reference rates auto-seeded, manually overridable
- Country on company (default) + machine (override, nullable)
- Sales stamped with tax_rate_snapshot + tax_amount + price_net at INSERT time
- Inclusive pricing: item_price is gross, price_net = item_price / (1 + rate)
- DATEV Buchungsstapel is primary export format (Lexware has no direct import)
- TSE not required for vending machines (KassenSichV exemption)
- getCurrentRate sorts by valid_from DESC to pick newest valid rate
- Tax rate modal includes optional valid_to for temporal rate changes

### Git State
Branch: main

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started
- Warehouse positions duplicate product bug (ON CONFLICT error)

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-04-05
Stopped at: Phase 09 complete, ready to plan Phase 10
Next action: /paul:plan for Phase 10 (tax-backfill-validation)
Resume file: .paul/ROADMAP.md

---
*STATE.md — Updated after every significant action*
