# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-04-09)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Mobile Storefront v1.7 — Phase 15 (mobile-payment)

## Current Position

Milestone: Mobile Storefront (v1.7)
Phase: 15 of 15 (mobile-payment) — Not started
Plan: Not started
Status: Ready to plan
Last activity: 2026-04-09 — Phase 14 complete, transitioned to Phase 15

Progress:
- Milestone v1.7: [█████░░░░░] 50%
- Phase 15: [░░░░░░░░░░] 0%

## Loop Position

Current loop state:
```
PLAN ──▶ APPLY ──▶ UNIFY
  ○        ○        ○     [Ready for new PLAN]
```

## Accumulated Context

### Decisions
- Public Storefront: URL scheme `/m/[subdomain]` using embeddeds.subdomain (bigserial)
- Public Storefront: Edge function with service_role bypasses RLS for public read-only data
- Public Storefront: MDB slave cannot force vend — credit delivery only, customer selects on machine
- Public Storefront: Dark mode via existing app-level head script, no per-page handling
- Public Storefront: Rate limit 10 product wishes per machine per hour
- Frontend: No toast library — use inline banners for errors/info

### Git State
Branch: main
Last commit: pending (phase 14 commit)

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started
- Warehouse positions duplicate product bug (ON CONFLICT error)
- DATEV account numbers hardcoded SKR03 — make configurable in future
- Restock notification email sending: subscriptions collected but delivery requires SMTP setup
- Management dashboard UI for viewing restock subscriptions and product wishes

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-04-09
Stopped at: Phase 14 complete, ready to plan Phase 15
Next action: /paul:plan for Phase 15 (mobile-payment)
Resume file: .paul/ROADMAP.md

---
*STATE.md — Updated after every significant action*
