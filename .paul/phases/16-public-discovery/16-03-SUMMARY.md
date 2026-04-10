---
phase: 16-public-discovery
plan: 03
subsystem: ui, api
tags: [operator-page, navigation, discovery, leaflet, nuxt]

requires:
  - phase: 16-public-discovery plan 01
    provides: machine UUID URL, public_listing column
  - phase: 16-public-discovery plan 02
    provides: public-machines-list edge function, Leaflet map pattern
provides:
  - Per-operator public page /m/o/[company_id]
  - Back navigation link on machine detail page
  - Extended public-machines-list with company_id filter
  - company_name in public-machine-data response
affects: [management-ui]

tech-stack:
  added: []
  patterns:
    - Reuse edge function with optional filter param (not new endpoint)
    - Shared Leaflet loading pattern (duplicated intentionally, small enough to avoid premature abstraction)

key-files:
  created:
    - management-frontend/app/pages/m/o/[company_id].vue
  modified:
    - Docker/supabase/functions/public-machines-list/index.ts
    - Docker/supabase/functions/public-machine-data/index.ts
    - management-frontend/app/pages/m/[machine_id].vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Extend public-machines-list with company_id param instead of new endpoint — reuses code, consistent API"
  - "Duplicate Leaflet loader in operator page — small enough, avoids premature abstraction"
  - "Empty response when filtered: returns company object even if machines array is empty — lets page show operator name"
  - "Back link only renders if company_id AND company_name present — graceful fallback if company data missing"

patterns-established:
  - "Optional filter parameter pattern: same endpoint, conditional query + response shape"
  - "Navigation loop: /m/ → detail → operator → /m/ — complete user journey"
  - "Back link text uses company name for context, not generic 'back'"

duration: 25min
started: 2026-04-10T09:25:00Z
completed: 2026-04-10T09:50:00Z
---

# Phase 16 Plan 03: Operator Page + Back Navigation Summary

**Per-operator discovery page at `/m/o/[company_id]` with Leaflet map of only that operator's public machines, plus a "back to operator machines" link on every detail page. Customers who found one machine via QR code can now discover other machines from the same operator.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~25min |
| Started | 2026-04-10T09:25Z |
| Completed | 2026-04-10T09:50Z |
| Tasks | 2 completed |
| Files modified | 6 (1 created, 5 modified) |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Edge function filters by company_id | Pass | company_id param validated as UUID, returns 400 invalid, 404 not found, response includes company object |
| AC-2: public-machine-data returns company_name | Pass | Field added to companies query, included in response |
| AC-3: Operator page loads at /m/o/[company_id] | Pass | Page shows "SnackFlow GmbH", map with markers, list with all 3 machines |
| AC-4: Back link on detail page | Pass | "← Alle Automaten von SnackFlow GmbH" at top, href: /m/o/be324c63... |
| AC-5: Operator not found | Pass | /m/o/00000000-... shows "Operator nicht gefunden" + back link |
| AC-6: Operator with no public machines | Pass | Empty state + company name both render correctly |

## Accomplishments

- Complete navigation loop: `/m/` (global) → `/m/[id]` (detail) → `/m/o/[company]` (operator) → `/m/` (global)
- Operators get their own "mini-brand page" reachable from every machine QR code
- Customers can discover other machines by the same operator
- All 6 acceptance criteria verified with screenshots
- No database changes needed — extended existing tables and endpoints

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `management-frontend/app/pages/m/o/[company_id].vue` | Created | Operator discovery page (map + list + back to /m/) |
| `Docker/supabase/functions/public-machines-list/index.ts` | Modified | Optional company_id filter, company object in response |
| `Docker/supabase/functions/public-machine-data/index.ts` | Modified | Added company_name to response |
| `management-frontend/app/pages/m/[machine_id].vue` | Modified | Back link banner with operator name |
| `management-frontend/i18n/locales/en.json` | Modified | Operator + backToOperator keys |
| `management-frontend/i18n/locales/de.json` | Modified | Operator + backToOperator keys |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Extend existing endpoint vs new | Same data shape, just filtered — cleaner API | No new function registration, shared code |
| Duplicate Leaflet loader | Small function, different page context, avoiding premature abstraction | Slightly more code, clearer boundaries |
| Back link only if both company_id AND company_name exist | Graceful fallback when data missing | No broken links |
| Include company object even in empty response | UI can show operator name with empty state | Better UX for valid-but-empty operators |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 0 | — |
| Scope additions | 0 | — |
| Deferred | 0 | — |

**Total impact:** Plan executed exactly as written.

### Auto-fixed Issues

None.

### Deferred Items

None.

## Issues Encountered

None — all features worked first try.

## Next Phase Readiness

**Ready:**
- Plan 04 can build management UI (toggle + QR code generator) using existing `public_listing` column and stable URLs
- QR codes in Plan 04 will point to `/m/[machine_id]` which is now stable across device swaps
- Operator page URL `/m/o/[company_id]` could also be QR-codable in future (not in scope for Plan 04)

**Concerns:**
- Leaflet code duplication between `/m/` and `/m/o/[company]` — could be refactored into a composable if a third map view is added later

**Blockers:**
- None

---
*Phase: 16-public-discovery, Plan: 03*
*Completed: 2026-04-10*
