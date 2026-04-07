# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-04-07)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Kassenbuch v1.6 — GoBD-konformes Kassenbuch

## Current Position

Milestone: Kassenbuch (v1.6)
Phase: 13 of 13 (cash-book-frontend)
Plan: 13-01 unified, 13-02 ready for APPLY
Status: APPLY ready for Plan 13-02
Last activity: 2026-04-07 — Plan 13-01 unified, proceeding to 13-02

Progress:
- Kassenbuch v1.6: [███████░░░] 70%
- Phase 13: [█████░░░░░] 50% (1 of 2 plans complete)

## Loop Position

Current loop state (Plan 13-02):
```
PLAN ──▶ APPLY ──▶ UNIFY
  ✓        ○        ○     [Plan 13-02 approved, executing]
```

## Accumulated Context

### Decisions
- Kassenbuch: 1-n Barkassen per company, machines assigned via vendingMachine.cash_book_id
- Kassenbuch: GoBD corrections via Stornobuchung (reversal entry), never UPDATE/DELETE
- Kassenbuch: Hash chain SHA256(entry_number + type + amount + balance_after + prev_hash)
- Kassenbuch: Theoretical cash aggregated across all assigned machines per Barkasse
- Frontend: No toast library — use inline banners for errors/info
- Frontend: Split Phase 13 into 2 plans (shell + dialogs/PDF)

### Git State
Branch: main
Last commit: 723e17c feat(cash-book-infrastructure)

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started
- Warehouse positions duplicate product bug (ON CONFLICT error)
- DATEV account numbers hardcoded SKR03 — make configurable in future

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-04-07
Stopped at: Plan 13-01 unified, executing Plan 13-02
Next action: /paul:apply .paul/phases/13-cash-book-frontend/13-02-PLAN.md
Resume file: .paul/phases/13-cash-book-frontend/13-02-PLAN.md

---
*STATE.md — Updated after every significant action*
