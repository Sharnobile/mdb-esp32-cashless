# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-04-05)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Steuer-Berichte v1.5 — MILESTONE COMPLETE

## Current Position

Milestone: Steuer-Berichte (v1.5) — COMPLETE
Phase: All 3 phases complete (09, 10, 11)
Plan: All plans executed and unified
Status: Milestone v1.5 complete
Last activity: 2026-04-05 — Phase 11 complete, milestone done

Progress:
- Steuer-Berichte v1.5: [██████████] 100%
- Phase 09: [██████████] 100% (2 plans)
- Phase 10: [██████████] 100% (1 plan)
- Phase 11: [██████████] 100% (1 plan)

## Loop Position

All loops closed.

## Accumulated Context

### Decisions
- Tax classes + tax rates table (not simple field on category) — future-proof for multi-country
- System-wide reference rates auto-seeded, manually overridable
- Country on company (default) + machine (override, nullable)
- Sales stamped with tax_rate_snapshot + tax_amount + price_net at INSERT time
- Inclusive pricing: item_price is gross, price_net = item_price / (1 + rate)
- DATEV Buchungsstapel is primary export format (Lexware has no direct import)
- TSE not required for vending machines (KassenSichV exemption)
- Client-side CSV generation, no server-side export
- Payment filters affect all views + exports
- VAT breakdown table added per user request

### Git State
Branch: main

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started
- Warehouse positions duplicate product bug (ON CONFLICT error)
- DATEV account numbers hardcoded SKR03 — make configurable in future

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-04-05
Stopped at: Milestone v1.5 Steuer-Berichte complete
Next action: /paul:complete-milestone or start next milestone
Resume file: .paul/ROADMAP.md

---
*STATE.md — Updated after every significant action*
