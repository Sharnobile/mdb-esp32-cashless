# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-04-10)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Milestone v1.8 Public Discovery — COMPLETE

## Current Position

Milestone: Public Discovery (v1.8) — COMPLETE
Phase: 16 of 16 (public-discovery) — Complete
Plan: All 4 plans complete
Status: Milestone complete, ready for next milestone
Last activity: 2026-04-10 — Milestone v1.8 complete

Progress:
- Milestone v1.8: [██████████] 100%

## Loop Position

All loops closed.

## Accumulated Context

### Decisions
- Public Discovery: URL uses vendingMachine.id UUID (stable, not enumerable, survives device swaps)
- Public Discovery: public_listing flag per machine (opt-out for private machines)
- Public Discovery: Leaflet + OpenStreetMap (DSGVO-friendly, CDN-loaded, no npm install)
- Public Discovery: Public list endpoints expose only human-readable names, never UUIDs beyond machine_id
- Public Discovery: company_id exposed in single-machine endpoint for operator navigation
- Public Discovery: Auth middleware handles bare /m AND /m/* (Nuxt normalizes trailing slash)
- Public Discovery: Settings tab pattern for admin-only machine configuration
- Public Discovery: window.location.origin for public URL base (dev/LAN/prod)
- Mobile Payment: Hybrid confirmation (client confirm-payment + webhook backup)
- Mobile Payment: Per-company Stripe keys + shared deliver-credit.ts module

### Git State
Branch: main
Last commit: ba0a1ef feat(mobile-payment)
Uncommitted: Phase 16 (all 4 plans) — will commit as part of transition

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started
- Warehouse positions duplicate product bug (ON CONFLICT error)
- DATEV account numbers hardcoded SKR03 — make configurable in future
- Restock notification email sending: subscriptions collected but delivery requires SMTP setup
- Management dashboard UI for viewing restock subscriptions and product wishes
- Apple Pay domain registration is a manual operator step per domain
- Map clustering not implemented — will be needed at scale (>1000 machines)
- Leaflet CDN external dependency — acceptable since map gracefully degrades to list
- QR code is PNG only — SVG/PDF could be added in future
- No bulk toggle for public_listing across multiple machines — future
- Pre-existing console warnings (IconDeviceMobile, onUnmounted) — unrelated to phase work

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-04-10
Stopped at: Milestone v1.8 complete (all 4 plans in Phase 16)
Next action: Start next milestone or review accomplishments
Resume file: .paul/ROADMAP.md

---
*STATE.md — Updated after every significant action*
