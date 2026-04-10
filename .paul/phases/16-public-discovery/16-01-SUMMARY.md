---
phase: 16-public-discovery
plan: 01
subsystem: api, database, ui
tags: [uuid, url-migration, privacy, stripe, supabase, nuxt]

requires:
  - phase: 14-public-storefront
    provides: Public page /m/[subdomain] with subdomain-based URL
  - phase: 15-mobile-payment
    provides: Payment edge functions using subdomain
provides:
  - Stable UUID-based public URLs (/m/[machine_uuid])
  - public_listing column on vendingMachine for per-machine privacy
  - UUID validation in all payment edge functions
  - Support for machines without linked device (basic public page)
affects: [public-map-index, operator-page, management-ui]

tech-stack:
  added: []
  patterns:
    - UUID validation regex in edge functions
    - Lookup chain: vendingMachine → embeddeds (reversed from Phase 14)
    - Optional embedded device (machine can exist without device, shows null status)

key-files:
  created:
    - Docker/supabase/migrations/20260410000000_public_listing.sql
  modified:
    - Docker/supabase/functions/public-machine-data/index.ts
    - Docker/supabase/functions/create-payment-intent/index.ts
    - Docker/supabase/functions/confirm-payment/index.ts
  renamed:
    - management-frontend/app/pages/m/[subdomain].vue → [machine_id].vue

key-decisions:
  - "Use vendingMachine.id UUID instead of new short column — no migration, not enumerable"
  - "Breaking change for /m/[subdomain] — acceptable since Phase 14 just shipped, no printed QR codes"
  - "Verify payment via PI metadata.machine_id (not company_id) for stronger cross-machine protection"
  - "Machine without device (embedded IS NULL) shows basic page with null status, no payment"

patterns-established:
  - "Public URLs use stable business entity IDs (vendingMachine.id), not device IDs"
  - "UUID validation via regex in all public edge functions"
  - "public_listing boolean flag pattern for per-entity discovery opt-out"

duration: 25min
started: 2026-04-10T07:00:00Z
completed: 2026-04-10T07:25:00Z
---

# Phase 16 Plan 01: URL Migration to UUID + Privacy Column Summary

**Migrated public URL scheme from device-based `embeddeds.subdomain` to stable `vendingMachine.id` UUID, fixing the architectural flaw where replacing a broken ESP32 would invalidate all printed QR codes. Added `public_listing` column for per-machine discovery opt-out.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~25min |
| Started | 2026-04-10T07:00Z |
| Completed | 2026-04-10T07:25Z |
| Tasks | 3 completed |
| Files modified | 5 (1 created, 3 modified, 1 renamed) |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Migration adds public_listing column | Pass | Column exists with default true, supabase migration up succeeded |
| AC-2: Public page loads via machine UUID | Pass | /m/3b55e13f-... loads full page with all features |
| AC-3: Payment flow works with machine_id | Pass | create-payment-intent returns clientSecret, confirm-payment validates UUID |
| AC-4: Old /m/[subdomain] URLs are gone | Pass | /m/2 shows "Automat nicht gefunden" |
| AC-5: Notify + wish still work | Pass | Both use data.value.machine_id from API response, no changes needed |

## Accomplishments

- URL scheme migrated from unstable device subdomain to stable machine UUID
- Printed QR codes will survive device swaps (the core architectural fix)
- Per-machine privacy foundation via `public_listing` column (will power Plan 02/03 discovery views)
- Edge functions now support machines without linked devices (graceful fallback)
- UUID validation prevents SQL-injection-style attacks via malformed parameters

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260410000000_public_listing.sql` | Created | Add public_listing column with comment |
| `Docker/supabase/functions/public-machine-data/index.ts` | Modified | Query by machine UUID, optional embedded lookup, expose company_id in response |
| `Docker/supabase/functions/create-payment-intent/index.ts` | Modified | Accept machine_id UUID, direct vendingMachine lookup, drop subdomain from metadata |
| `Docker/supabase/functions/confirm-payment/index.ts` | Modified | Accept machine_id UUID, verify via metadata.machine_id (not company_id) |
| `management-frontend/app/pages/m/[subdomain].vue` → `[machine_id].vue` | Renamed + Modified | Client-side UUID validation, pass machineId to all API calls |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Expose `company_id` in public-machine-data response | Plan 03 needs it for "back to all operator machines" link | Makes future operator page trivial to implement |
| Verify PI metadata.machine_id (not company_id) | Stronger cross-machine abuse protection — prevents cross-machine payment replay within same company | Requires create-payment-intent to include machine_id in metadata (already does) |
| Handle optional embedded device | Machine can exist without device assignment | Public page shows null status, payment returns 503 "no device" — graceful |
| Drop `subdomain` from PaymentIntent metadata | No longer needed with machine_id | Slight metadata cleanup, no functional impact |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 0 | — |
| Scope additions | 1 | Added company_id to API response |
| Deferred | 0 | — |

**Total impact:** Minor scope addition to support future plans, no scope creep.

### Scope Addition: company_id in API response

- **What:** `public-machine-data` response now includes `company_id` field
- **Why:** Plan 03 will need to build a link "← Alle Automaten von [Operator]" on the detail page, which requires knowing which operator owns this machine
- **Alternative considered:** Fetch company_id separately in Plan 03 via a second query — rejected because we already load it to check Stripe keys
- **Impact:** One extra field in JSON response, no behavior change

## Issues Encountered

None.

## Next Phase Readiness

**Ready:**
- Phase 16 Plan 02 can build `/m/` global map using `vendingMachine` table with `public_listing = true` filter
- Plan 03 can build `/m/o/[company_id]` — company_id is already exposed in the detail page API response for the "back" link
- Plan 04 can add `public_listing` toggle UI — column already exists with default true

**Concerns:**
- None — the breaking change from subdomain to UUID is intentional and acceptable

**Blockers:**
- None

---
*Phase: 16-public-discovery, Plan: 01*
*Completed: 2026-04-10*
