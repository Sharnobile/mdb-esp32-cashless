# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-04-07)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Kassenbuch v1.6 — GoBD-konformes Kassenbuch

## Current Position

Milestone: Kassenbuch (v1.6)
Phase: 13 of 13 (cash-book-frontend)
Plan: Not started
Status: Ready to plan
Last activity: 2026-04-07 — Phase 12 complete, transitioned to Phase 13

Progress:
- Kassenbuch v1.6: [█████░░░░░] 50%

## Loop Position

Current loop state:
```
PLAN ──▶ APPLY ──▶ UNIFY
  ○        ○        ○     [Ready for first PLAN of Phase 13]
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
- Client-side CSV generation, no server-side export
- Payment filters affect all views + exports
- VAT breakdown table added per user request
- Kassenbuch: 1-n Barkassen per company (not 1:1 machine), machines assigned via vendingMachine.cash_book_id
- Kassenbuch: GoBD corrections via Stornobuchung (reversal entry), never UPDATE/DELETE
- Kassenbuch: Hash chain SHA256(entry_number + type + amount + balance_after + prev_hash)
- Kassenbuch: Theoretical cash aggregated across all assigned machines per Barkasse

### Git State
Branch: main

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started
- Warehouse positions duplicate product bug (ON CONFLICT error)
- DATEV account numbers hardcoded SKR03 — make configurable in future
- Migration 20260407000000 not live-tested yet — first test when DB starts

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-04-07
Stopped at: Phase 12 complete, ready to plan Phase 13
Next action: /paul:plan for Phase 13
Resume file: .paul/ROADMAP.md

---
*STATE.md — Updated after every significant action*
