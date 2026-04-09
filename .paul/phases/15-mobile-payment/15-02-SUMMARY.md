---
phase: 15-mobile-payment
plan: 02
subsystem: ui
tags: [stripe, payment-element, apple-pay, google-pay, vue, tailwind]

requires:
  - phase: 15-mobile-payment plan 01
    provides: create-payment-intent, confirm-payment edge functions
provides:
  - Stripe Payment Element UI on public storefront page
  - Product selection → payment → credit delivery flow
  - payment_enabled flag in public-machine-data API
affects: []

tech-stack:
  added: [stripe.js (CDN)]
  patterns:
    - Dynamic Stripe.js loading (only when payment_enabled)
    - Payment Element with redirect:'if_required' for in-page confirmation

key-files:
  modified:
    - management-frontend/app/pages/m/[subdomain].vue
    - Docker/supabase/functions/public-machine-data/index.ts
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Dynamic Stripe.js load: only when payment_enabled, avoids unnecessary CDN request"
  - "redirect:'if_required' keeps user on page for Apple Pay/Google Pay/most cards"
  - "payment_enabled flag from API avoids exposing Stripe keys in public data endpoint"

duration: 20min
started: 2026-04-09T21:15:00Z
completed: 2026-04-09T21:35:00Z
---

# Phase 15 Plan 02: Payment UI on Public Storefront Summary

**Stripe Payment Element with Apple Pay/Google Pay/card on the public storefront page — product selection, payment modal, credit delivery confirmation, and graceful fallback for machines without Stripe.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~20min |
| Started | 2026-04-09T21:15Z |
| Completed | 2026-04-09T21:35Z |
| Tasks | 2 completed (1 auto + 1 checkpoint) |
| Files modified | 4 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Product selection triggers payment | Pass | "Kaufen" button opens payment modal |
| AC-2: Stripe Payment Element loads | Pass | Mounts with dark/light theme, shows card + wallets |
| AC-3: Successful payment delivers credit | Pass | confirm-payment called, success screen shown |
| AC-4: Payment error handling | Pass | Declined cards show error, dismiss available |
| AC-5: No payment without Stripe keys | Pass | No buy buttons when payment_enabled=false |

## Accomplishments

- Payment flow: product tap → modal → Stripe Payment Element → confirm → credit delivery → success screen
- Dynamic Stripe.js loading (CDN, only when needed)
- Payment Element auto-adapts theme (dark/light) and shows Apple Pay/Google Pay on supported devices
- Graceful degradation: machines without Stripe remain view-only storefronts
- Human-verified end-to-end with Stripe test keys

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `management-frontend/app/pages/m/[subdomain].vue` | Modified | Added payment state, Stripe.js loading, payment modal, buy buttons |
| `Docker/supabase/functions/public-machine-data/index.ts` | Modified | Added payment_enabled flag + company query |
| `management-frontend/i18n/locales/en.json` | Modified | Payment flow translations (10 keys) |
| `management-frontend/i18n/locales/de.json` | Modified | Payment flow translations (10 keys) |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Dynamic script load for Stripe.js | No CDN request for view-only machines | Better performance for non-payment pages |
| redirect:'if_required' | Keeps user on page for most payment methods | Better UX, avoids redirect loop |
| Theme detection via documentElement.classList | Matches existing dark mode mechanism | Stripe Element matches page theme |

## Deviations from Plan

None — plan executed as written, human verification approved.

## Issues Encountered

None.

## Next Phase Readiness

**Ready:**
- Complete mobile payment flow operational
- Milestone v1.7 fully delivered

**Concerns:**
- Apple Pay requires domain registration in Stripe Dashboard (manual operator step)
- Full end-to-end requires operator to configure Stripe test/live keys

**Blockers:**
- None

---
*Phase: 15-mobile-payment, Plan: 02*
*Completed: 2026-04-09*
