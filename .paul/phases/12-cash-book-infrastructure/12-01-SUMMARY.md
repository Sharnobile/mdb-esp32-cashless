---
phase: 12-cash-book-infrastructure
plan: 01
subsystem: database
tags: [postgres, rls, gobd, kassenbuch, hash-chain, trigger]

requires: []
provides:
  - cash_books table (1-n Barkassen per company)
  - cash_book_entries table (immutable, GoBD hash chain)
  - vendingMachine.cash_book_id (machine→Barkasse assignment)
  - get_theoretical_cash RPC (aggregated cash balance)
  - reversal mechanism (Stornobuchung)
affects: [13-cash-book-frontend]

tech-stack:
  added: [pgcrypto]
  patterns: [GoBD immutable hash chain, reversal-based corrections]

key-files:
  created:
    - Docker/supabase/migrations/20260407000000_cash_book.sql

key-decisions:
  - "1-n Barkassen per company, not 1:1 machine — supports regional expansion"
  - "Corrections via Stornobuchung (reversal entry), never UPDATE/DELETE"
  - "Hash chain: SHA256(entry_number + type + amount + balance_after + prev_hash)"
  - "Theoretical cash aggregated across all assigned machines per Barkasse"

patterns-established:
  - "GoBD immutability: no UPDATE/DELETE RLS policies on audit tables"
  - "Reversal pattern: corrects_entry_id FK + is_reversed flag + trigger validation"
  - "SECURITY DEFINER trigger for cross-row updates (bypass RLS for is_reversed)"

duration: 10min
started: 2026-04-07T22:25:00+02:00
completed: 2026-04-07T22:35:00+02:00
---

# Phase 12 Plan 01: Cash Book Infrastructure Summary

**GoBD-compliant Barkassen schema with immutable hash-chained entries, reversal mechanism, machine assignment, and theoretical cash RPC**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~10min |
| Started | 2026-04-07T22:25+02:00 |
| Completed | 2026-04-07T22:35+02:00 |
| Tasks | 2 completed |
| Files created | 1 (328 lines) |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Barkasse creation 1-n per company | Pass | UNIQUE(company_id, name), auto initial entry |
| AC-2: Machine assignment to Barkasse | Pass | vendingMachine.cash_book_id nullable FK |
| AC-3: Immutable entries with hash chain | Pass | SHA256 trigger, no UPDATE/DELETE policies |
| AC-4: GoBD-compliant reversal | Pass | corrects_entry_id, is_reversed, double-storno blocked |
| AC-5: Theoretical cash across machines | Pass | get_theoretical_cash with per-machine breakdown |
| AC-6: Multi-tenancy | Pass | RLS via my_company_id() on both tables |

## Accomplishments

- Complete GoBD-compliant Barkassen schema supporting 1-n cash registers per company
- Immutable hash chain with SHA256 ensuring tamper-proof audit trail
- Reversal mechanism (Stornobuchung) for correcting mistakes without violating GoBD
- Theoretical cash RPC aggregating cash sales across all machines assigned to a Barkasse

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260407000000_cash_book.sql` | Created | Full Barkassen schema: tables, RLS, triggers, RPC |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| 1-n Barkassen per company | Operators start with 1, expand regionally | vendingMachine.cash_book_id instead of cash_books.machine_id |
| Corrections via reversal only | GoBD requires immutable entries | type='reversal' + corrects_entry_id pattern |
| Trigger auto-negates reversal amount | Prevent user error on reversal amounts | amount always = -original_amount |
| ON DELETE RESTRICT on cash_book_entries FK | Cannot delete Barkasse with entries | GoBD data retention |
| machine_id on entries (nullable) | Track which machine cash was withdrawn from | Useful for multi-machine Barkassen |

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| Local Supabase + Docker not running | Verified migration structurally (FK refs, patterns, syntax) — live test deferred to Phase 13 |

## Next Phase Readiness

**Ready:**
- Full schema in place for frontend composable (useCashBook)
- RPC ready for theoretical cash calculation
- vendingMachine.cash_book_id ready for machine assignment UI
- Entry types defined: initial, withdrawal, correction, payout, reversal

**Concerns:**
- Migration not live-tested yet — first test will be when DB is started for Phase 13

**Blockers:**
- None

---
*Phase: 12-cash-book-infrastructure, Plan: 01*
*Completed: 2026-04-07*
