# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-03-19)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** All milestones complete — ready for next

## Current Position

Milestone: Awaiting next milestone
Phase: None active
Plan: None
Status: Milestones v1.1 + v1.2 + v1.3 complete — ready for next
Last activity: 2026-03-19 — Milestone v1.3 completed

Progress:
- AI Insights v1.1: [██████████] 100% ✓
- Warehouse v1.2: [██████████] 100% ✓
- Refill Tour v1.3: [██████████] 100% ✓

## Loop Position

Current loop state:
```
PLAN ──▶ APPLY ──▶ UNIFY
  ○        ○        ○     [Milestone complete - ready for next]
```

## Accumulated Context

### Decisions
- Per-company Anthropic API key (not global env var)
- `claude-haiku-4-5` model for structured JSON output
- Custom quantity adjuster shows user intent (customQty) not allocated amount (effectiveDeficit)
- `crypto.randomUUID` fallback for environments without Web Crypto
- `hasCritical` must include `current_stock === 0` to match initTour behavior

### Git State
Branch: main

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-03-19
Stopped at: Milestone v1.3 complete
Next action: /paul:discuss-milestone or /paul:milestone
Resume file: .paul/MILESTONES.md

---
*STATE.md — Updated after every significant action*
