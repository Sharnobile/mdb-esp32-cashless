# Project State

## Project Reference

See: .paul/PROJECT.md (updated 2026-04-09)

**Core value:** Vending machine operators can manage all the telemetry, monitor sales, and optimize inventory from a single dashboard
**Current focus:** Milestone v1.7 Mobile Storefront — COMPLETE

## Current Position

Milestone: Mobile Storefront (v1.7) — COMPLETE
Phase: 15 of 15 (mobile-payment) — Complete
Plan: All plans complete
Status: Milestone complete
Last activity: 2026-04-09 — Milestone v1.7 complete

Progress:
- Milestone v1.7: [██████████] 100%

## Loop Position

All loops closed.

## Accumulated Context

### Decisions
- Public Storefront: URL scheme `/m/[subdomain]` using embeddeds.subdomain (bigserial)
- Public Storefront: Edge function with service_role bypasses RLS for public read-only data
- Public Storefront: MDB slave cannot force vend — credit delivery only, customer selects on machine
- Mobile Payment: Hybrid confirmation (client confirm-payment + webhook backup)
- Mobile Payment: Per-company Stripe keys (stripe_secret_key, stripe_publishable_key, stripe_webhook_secret)
- Mobile Payment: Shared deliver-credit.ts module for XOR + MQTT
- Mobile Payment: npm:stripe@^17 for Deno, Stripe.js CDN for client
- Mobile Payment: payment_enabled flag in API avoids exposing keys
- Mobile Payment: redirect:'if_required' for in-page confirmation

### Git State
Branch: main
Last commit: ef164fa feat(public-storefront)

### Deferred Issues
- `supabase db reset` does not work locally — pre-existing issue
- SonarQube integration planned but not started
- Warehouse positions duplicate product bug (ON CONFLICT error)
- DATEV account numbers hardcoded SKR03 — make configurable in future
- Restock notification email sending: subscriptions collected but delivery requires SMTP setup
- Management dashboard UI for viewing restock subscriptions and product wishes
- Apple Pay domain registration is a manual operator step per domain

### Blockers/Concerns
None.

## Session Continuity

Last session: 2026-04-09
Stopped at: Milestone v1.7 complete
Next action: /paul:complete-milestone or start next milestone
Resume file: .paul/ROADMAP.md

---
*STATE.md — Updated after every significant action*
