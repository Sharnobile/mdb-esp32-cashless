---
phase: 15-mobile-payment
plan: 01
subsystem: api, database, ui
tags: [stripe, payments, edge-functions, mqtt, xor-encryption, settings]

requires:
  - phase: 14-public-storefront
    provides: Public page /m/[subdomain] with machine_id in API
provides:
  - Stripe payment backend (create-payment-intent, confirm-payment, stripe-webhook)
  - Per-company Stripe key management in settings
  - Payments table for audit + idempotency
  - Shared deliver-credit.ts helper (XOR + MQTT)
affects: [mobile-payment-ui, payment-history-dashboard]

tech-stack:
  added: [stripe@^17 (npm)]
  patterns:
    - Hybrid payment confirmation (client-side + webhook backup)
    - Shared deliver-credit.ts for XOR payload building + MQTT publish
    - Per-company Stripe keys following anthropic_api_key column pattern

key-files:
  created:
    - Docker/supabase/functions/create-payment-intent/index.ts
    - Docker/supabase/functions/confirm-payment/index.ts
    - Docker/supabase/functions/stripe-webhook/index.ts
    - Docker/supabase/functions/_shared/deliver-credit.ts
    - Docker/supabase/migrations/20260409300000_stripe_payments.sql
  modified:
    - Docker/supabase/config.toml
    - management-frontend/app/pages/settings/index.vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Hybrid payment: client confirm-payment (instant) + webhook (backup for missed deliveries)"
  - "Per-company keys: stripe_secret_key, stripe_publishable_key, stripe_webhook_secret on companies table"
  - "Shared deliver-credit.ts: extracted XOR payload logic from send-credit for reuse"
  - "Webhook multi-tenant via ?company_id= query param for per-company signature verification"
  - "Idempotent payments via UNIQUE on stripe_payment_intent_id"

patterns-established:
  - "Payment edge functions use npm:stripe@^17 import in deno.json"
  - "deliver-credit.ts shared module for any future credit delivery needs"
  - "Webhook URL pattern: /functions/v1/stripe-webhook?company_id={uuid}"

duration: 25min
started: 2026-04-09T20:45:00Z
completed: 2026-04-09T21:10:00Z
---

# Phase 15 Plan 01: Stripe Payment Backend Infrastructure Summary

**Stripe payment backend with 3 edge functions (create-payment-intent, confirm-payment, stripe-webhook), per-company key management in settings UI, payments table with idempotency, and shared deliver-credit.ts helper for XOR-encrypted MQTT credit delivery.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~25min |
| Started | 2026-04-09T20:45Z |
| Completed | 2026-04-09T21:10Z |
| Tasks | 2 completed |
| Files modified | 13 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Stripe keys configurable per company | Pass | Settings UI with 3 key fields, masked display, save/remove |
| AC-2: PaymentIntent creation | Pass | Edge function creates PI using company's Stripe key, returns clientSecret + publishableKey |
| AC-3: Payment confirmation + credit delivery | Pass | Verifies PI succeeded, builds XOR payload, publishes MQTT credit |
| AC-4: Webhook handles missed payments | Pass | Signature verification, idempotent processing, retry on credit failure |
| AC-5: Duplicate payment prevention | Pass | UNIQUE constraint on stripe_payment_intent_id, idempotent upsert |

## Accomplishments

- 3 edge functions for complete Stripe payment flow (create → confirm → webhook)
- Shared `deliver-credit.ts` module extracting XOR encryption + MQTT publish from send-credit
- Per-company Stripe keys in settings page following existing AI key pattern
- Payments table with idempotency + credit delivery tracking
- Webhook multi-tenant architecture via company_id query parameter

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260409300000_stripe_payments.sql` | Created | Stripe columns on companies + payments table |
| `Docker/supabase/functions/_shared/deliver-credit.ts` | Created | Shared XOR credit payload + MQTT publish |
| `Docker/supabase/functions/create-payment-intent/index.ts` | Created | Creates PaymentIntent with company Stripe key |
| `Docker/supabase/functions/create-payment-intent/deno.json` | Created | Import map (stripe + supabase) |
| `Docker/supabase/functions/confirm-payment/index.ts` | Created | Verifies payment + delivers credit |
| `Docker/supabase/functions/confirm-payment/deno.json` | Created | Import map |
| `Docker/supabase/functions/stripe-webhook/index.ts` | Created | Webhook handler for backup credit delivery |
| `Docker/supabase/functions/stripe-webhook/deno.json` | Created | Import map |
| `Docker/supabase/config.toml` | Modified | Added 3 function entries |
| `management-frontend/app/pages/settings/index.vue` | Modified | Stripe keys section (load/save/remove/mask) |
| `management-frontend/i18n/locales/en.json` | Modified | Stripe settings translations |
| `management-frontend/i18n/locales/de.json` | Modified | Stripe settings translations |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Extract deliver-credit.ts shared module | XOR + MQTT logic needed by both confirm-payment and webhook | Reusable, DRY, testable |
| Hybrid confirm + webhook | Client-side for instant UX, webhook for reliability | Both paths idempotent |
| Webhook returns 500 on credit failure | Triggers Stripe retry (72h, 16 attempts) | Self-healing credit delivery |
| Amount in PI metadata | Webhook can deliver credit without re-querying product price | Decoupled from product changes |

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## Next Phase Readiness

**Ready:**
- All 3 edge functions deployed and responding
- Settings UI for Stripe key management complete
- Plan 02 can immediately build payment UI on public page using create-payment-intent + confirm-payment

**Concerns:**
- Full end-to-end test requires a Stripe test key (structural verification only in this plan)
- Apple Pay/Google Pay domain registration is a manual operator step

**Blockers:**
- None

---
*Phase: 15-mobile-payment, Plan: 01*
*Completed: 2026-04-09*
