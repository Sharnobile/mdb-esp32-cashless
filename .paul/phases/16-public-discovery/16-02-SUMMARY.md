---
phase: 16-public-discovery
plan: 02
subsystem: ui, api
tags: [leaflet, openstreetmap, map, discovery, nuxt]

requires:
  - phase: 16-public-discovery plan 01
    provides: vendingMachine.public_listing column, machine UUID URL scheme
provides:
  - Global public map at /m/ with all public machines
  - public-machines-list edge function (sanitized data)
  - Leaflet + OpenStreetMap integration pattern
affects: [operator-page, management-ui]

tech-stack:
  added: [leaflet@1.9.4 (CDN), openstreetmap tiles]
  patterns:
    - CDN-loaded Leaflet in Nuxt (avoids SSR issues, no npm install)
    - divIcon with inline HTML for custom markers
    - fitBounds for auto-centering on markers

key-files:
  created:
    - Docker/supabase/functions/public-machines-list/index.ts
    - management-frontend/app/pages/m/index.vue
  modified:
    - Docker/supabase/config.toml
    - management-frontend/app/middleware/auth.ts
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Leaflet via CDN (unpkg) — no npm install, lighter bundle, easier dynamic loading"
  - "OpenStreetMap tiles — DSGVO-friendly, no API keys, free"
  - "Fallback list shows ALL machines (including no-location) for accessibility"
  - "Expose only company_name (text), never company_id UUID — keeps API public-safe"

patterns-established:
  - "Client-only Leaflet loading pattern for Nuxt pages"
  - "Bare /m route + /m/* prefix both covered by auth middleware"
  - "Public list edge functions expose only human-readable data (names), never IDs"

duration: 20min
started: 2026-04-10T08:15:00Z
completed: 2026-04-10T08:35:00Z
---

# Phase 16 Plan 02: Global Map at /m/ Summary

**Interactive global discovery map at `/m/` using Leaflet + OpenStreetMap, showing all public vending machines with color-coded markers (online/offline) and a fallback list view. Customers can discover machines, see status at a glance, and navigate directly to detail pages.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~20min |
| Started | 2026-04-10T08:15Z |
| Completed | 2026-04-10T08:35Z |
| Tasks | 2 completed |
| Files modified | 7 (3 created, 4 modified) |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Edge function returns public machines | Pass | Returns 3 machines with sanitized data (no IDs, no secrets) |
| AC-2: Global map page loads at /m/ | Pass | Leaflet loads from CDN, OSM tiles render |
| AC-3: Markers are clickable and link to detail | Pass | Popup shows name, company, status, detail link verified |
| AC-4: Fallback list below the map | Pass | All 3 machines in card grid with navigation |
| AC-5: Empty state | Pass | Friendly message when no machines |

## Accomplishments

- Customers can discover all public vending machines on a global interactive map
- Color-coded markers (green=online, gray=offline) at a glance
- Popup with machine name, operator, status, and direct "Details ansehen" link
- Accessible fallback list works for machines without coordinates
- Zero new dependencies — Leaflet loaded from CDN, no npm install
- OSM tiles chosen over Google Maps for DSGVO/privacy friendliness

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/functions/public-machines-list/index.ts` | Created | Returns sanitized list of public machines |
| `Docker/supabase/functions/public-machines-list/deno.json` | Created | Import map |
| `management-frontend/app/pages/m/index.vue` | Created | Global map page with Leaflet + fallback list |
| `Docker/supabase/config.toml` | Modified | Added public-machines-list function entry |
| `management-frontend/app/middleware/auth.ts` | Modified | Fix: match `/m` without trailing slash |
| `management-frontend/i18n/locales/en.json` | Modified | publicMap translations |
| `management-frontend/i18n/locales/de.json` | Modified | publicMap translations |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Leaflet via CDN, not npm | Smaller bundle, no build-step integration issues, client-only naturally | No dependency on Nuxt SSR compatibility |
| OpenStreetMap tiles | Free, DSGVO-friendly, no API keys needed | Matches project's privacy-first approach |
| Only expose company_name (not company_id) | Public endpoint, minimize data exposure | Enumeration attacks against companies prevented |
| Include no-location machines in list | Fallback for accessibility and discovery | Operators can still list private-location machines |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 1 | Essential bug fix |
| Scope additions | 0 | — |
| Deferred | 0 | — |

**Total impact:** Minor bug fix, no scope creep.

### Auto-fixed Issue: Auth middleware trailing slash

- **Found during:** Task 2 verification (page redirected to /auth/login)
- **Issue:** Nuxt normalizes `/m/` → `/m` (no trailing slash). The auth middleware's `publicRoutes` only contained `/m/` and used `startsWith()`, so bare `/m` was not matched and got redirected to login.
- **Fix:** Removed `/m/` from publicRoutes, added explicit check: `if (to.path === '/m' || to.path.startsWith('/m/')) return`. Prevents `/m` from matching `/machines` (protected) while still covering `/m`, `/m/[id]`, `/m/o/[company]`.
- **Files:** `management-frontend/app/middleware/auth.ts`
- **Verification:** Navigated to `/m` successfully, page loads with map

## Issues Encountered

None.

## Next Phase Readiness

**Ready:**
- Plan 03 can build `/m/o/[company_id]` with the same edge function pattern (just filter by company_id)
- Plan 03 can add "← Alle Automaten" back link on detail page using `company_id` from public-machine-data response
- Plan 04 can add public_listing toggle + QR code generator

**Concerns:**
- Leaflet CDN is external dependency — if unpkg.com is down, map won't load (falls back to list view gracefully)
- For very large machine counts (>1000), pagination or bbox queries will be needed (noted in plan boundaries)

**Blockers:**
- None

---
*Phase: 16-public-discovery, Plan: 02*
*Completed: 2026-04-10*
