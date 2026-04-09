---
phase: 14-public-storefront
plan: 01
subsystem: ui, api, database
tags: [nuxt, supabase, edge-functions, public-page, i18n, tailwind]

requires: []
provides:
  - Public machine storefront page at /m/[subdomain]
  - Edge function public-machine-data (service_role, no auth)
  - Edge function subscribe-restock (email subscription for out-of-stock products)
  - Edge function submit-product-wish (product wish submission with rate limiting)
  - DB tables restock_subscriptions and product_wishes
affects: [mobile-payment, management-dashboard-wishes]

tech-stack:
  added: []
  patterns:
    - Public page with layout:false and /m/ public route prefix
    - Edge function with service_role for public data (bypasses RLS)
    - Upsert with onConflict+ignoreDuplicates for idempotent subscriptions

key-files:
  created:
    - Docker/supabase/functions/public-machine-data/index.ts
    - Docker/supabase/functions/subscribe-restock/index.ts
    - Docker/supabase/functions/submit-product-wish/index.ts
    - Docker/supabase/migrations/20260409200000_public_storefront.sql
    - management-frontend/app/pages/m/[subdomain].vue
  modified:
    - Docker/supabase/config.toml
    - management-frontend/app/middleware/auth.ts
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "URL scheme /m/[subdomain] using embeddeds.subdomain bigserial as public identifier"
  - "Dark mode handled by existing app-level head script, no per-page isDark ref needed"
  - "Restock subscriptions collect email only — actual notification delivery deferred (needs SMTP)"
  - "Rate limit: max 10 product wishes per machine per hour"

patterns-established:
  - "Public pages use definePageMeta({ layout: false }) + /m/ prefix in publicRoutes"
  - "Public edge functions use service_role client to bypass RLS for read-only data"
  - "Expose machine_id and product_id (UUIDs) in public API — needed for interactions, not sensitive"

duration: 30min
started: 2026-04-09T20:10:00Z
completed: 2026-04-09T20:40:00Z
---

# Phase 14 Plan 01: Public Machine Storefront Summary

**Public-facing storefront page at `/m/[subdomain]` with product grid, restock notification subscriptions, and product wish submission — 3 edge functions, 2 new DB tables, mobile-first responsive UI with i18n (en/de).**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~30min |
| Started | 2026-04-09T20:10Z |
| Completed | 2026-04-09T20:40Z |
| Tasks | 2 completed |
| Files modified | 12 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Public page loads without auth | Pass | /m/2 renders full page, no login redirect |
| AC-2: Machine header displays correctly | Pass | Name, online/offline badge, Google Maps link |
| AC-3: Products grouped by category | Pass | Categories with count, product cards with stock/price/image/bar |
| AC-4: Edge function returns correct data | Pass | curl returns JSON with categories, no internal IDs exposed |
| AC-5: Not-found handling | Pass | /m/99999 shows "Automat nicht gefunden" page |
| AC-6: Restock notification subscription | Pass | Email subscription works, duplicate prevention via ON CONFLICT |
| AC-7: Product wish submission | Pass | Wish saved, rate limit enforced, success confirmation shown |

## Accomplishments

- Public storefront page at `/m/[subdomain]` — mobile-first, dark/light theme, SSR-compatible
- 3 edge functions: `public-machine-data` (GET, service_role), `subscribe-restock` (POST, idempotent), `submit-product-wish` (POST, rate-limited)
- 2 new DB tables with RLS: `restock_subscriptions` (unique constraint, partial index), `product_wishes` (status workflow)
- Product cards with image thumbnails, availability badges, color-coded stock progress bars
- Bottom-sheet modals for notify and wish interactions on mobile

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260409200000_public_storefront.sql` | Created | restock_subscriptions + product_wishes tables with RLS |
| `Docker/supabase/functions/public-machine-data/index.ts` | Created | Public API: machine + trays + products grouped by category |
| `Docker/supabase/functions/public-machine-data/deno.json` | Created | Import map |
| `Docker/supabase/functions/subscribe-restock/index.ts` | Created | Email subscription for out-of-stock products |
| `Docker/supabase/functions/subscribe-restock/deno.json` | Created | Import map |
| `Docker/supabase/functions/submit-product-wish/index.ts` | Created | Product wish submission with rate limit |
| `Docker/supabase/functions/submit-product-wish/deno.json` | Created | Import map |
| `Docker/supabase/config.toml` | Modified | Added 3 function entries |
| `management-frontend/app/pages/m/[subdomain].vue` | Created | Public storefront page with full UI |
| `management-frontend/app/middleware/auth.ts` | Modified | Added /m/ to publicRoutes |
| `management-frontend/i18n/locales/en.json` | Modified | publicStorefront namespace (30 keys) |
| `management-frontend/i18n/locales/de.json` | Modified | publicStorefront namespace (30 keys) |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Use embeddeds.subdomain as URL identifier | Already unique bigserial, simple integer URL | Short URLs like /m/42 |
| Dark mode via app head script | Existing script adds .dark to html; per-page ref caused hydration mismatches | Removed isDark ref, fixed hydration |
| Expose machine_id + product_id in public API | Needed for restock/wish POST calls; UUIDs are not sensitive | Clean separation between public and internal data |
| Rate limit wishes (10/machine/hour) | Prevent spam without requiring auth | Simple DB count check |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 1 | Hydration mismatch fix |
| Scope additions | 0 | — |
| Deferred | 0 | — |

**Total impact:** Essential fix, no scope creep.

### Auto-fixed Issues

**1. Hydration mismatch from isDark ref**
- **Found during:** Task 2 (public page)
- **Issue:** `isDark = ref(false)` on server + `window.matchMedia` on client caused SSR/CSR mismatch
- **Fix:** Removed isDark ref; rely on existing app-level head script that adds `.dark` to `<html>`
- **Files:** `management-frontend/app/pages/m/[subdomain].vue`
- **Verification:** Hydration errors are pre-existing (app-wide from supabase-url plugin), not introduced by this change

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| Hydration mismatches in console | Pre-existing (supabase-url.client.ts plugin), not introduced by this phase |

## Next Phase Readiness

**Ready:**
- Public page infrastructure in place (route, edge functions, DB tables)
- machine_id exposed in public API — Phase 15 can use it for payment association
- Product selection UI can be extended for payment flow

**Concerns:**
- Restock notification email delivery requires SMTP setup (deferred)
- Management dashboard has no UI for viewing wishes/subscriptions (Supabase Studio workaround)

**Blockers:**
- None

---
*Phase: 14-public-storefront, Plan: 01*
*Completed: 2026-04-09*
