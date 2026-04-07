# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-04-07)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Kassenbuch v1.6 — COMPLETE

## Current Position

Milestone: Kassenbuch (v1.6) — COMPLETE
Phase: 13 of 13 (cash-book-frontend) — Complete
Plan: All plans complete
Status: Milestone complete
Last activity: 2026-04-07 — Milestone v1.6 complete

Progress:
- Kassenbuch v1.6: [██████████] 100%

## Loop Position

All loops closed.

## Accumulated Context

### Decisions
- Kassenbuch: 1-n Barkassen per company, machines assigned via vendingMachine.cash_book_id
- Kassenbuch: GoBD corrections via Stornobuchung (reversal entry), never UPDATE/DELETE
- Kassenbuch: Hash chain SHA256(entry_number + type + amount + balance_after + prev_hash)
- Kassenbuch: Theoretical cash aggregated across all assigned machines per Barkasse
- Kassenbuch: Withdrawal = POSITIVE (cash collected from machine INTO Barkasse)
- Kassenbuch: Payout = NEGATIVE (cash going OUT to bank)
- Kassenbuch: No auto-correction after withdrawal — difference is informational only
- Frontend: No toast library — use inline banners for errors/info
- Frontend: ssr: false for cash-book page (jspdf + component resolution)
- Frontend: jspdf via dynamic import (client-only)

### Git State
Branch: main
Last commit: b23e75d feat(cash-book-frontend)

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started
- Warehouse positions duplicate product bug (ON CONFLICT error)
- DATEV account numbers hardcoded SKR03 — make configurable in future

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-04-07
Stopped at: Milestone v1.6 complete
Next action: /paul:complete-milestone or start next milestone
Resume file: .paul/ROADMAP.md

---
*STATE.md — Updated after every significant action*
