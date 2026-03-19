---
phase: 03-insights-ui
plan: 01
subsystem: ui
tags: [vue, nuxt, sheet, composable, i18n, ai-insights]

requires:
  - phase: 02-insights-edge-function
    provides: machine-insights edge function + per-company API key
provides:
  - useInsights composable
  - AI Insights button + Sheet on /machines/[id]
  - Full i18n (EN + DE)
affects: []

tech-stack:
  added: []
  patterns: [Sheet overlay for on-demand async content]

key-files:
  created:
    - management-frontend/app/composables/useInsights.ts
  modified:
    - management-frontend/app/pages/machines/[id].vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Sheet (not Dialog) for recommendations — better for scrollable content on mobile"
  - "Button visible to all users (not admin-only) — viewers can see insights too"

patterns-established:
  - "On-demand async Sheet: button click → open sheet → fetch → show loading/error/results"

duration: ~20min
completed: 2026-03-19
---

# Phase 03 Plan 01: AI Insights UI Summary

**useInsights composable + AI Insights button on machine detail page with Sheet overlay showing priority-sorted recommendations, summary, and full i18n.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~20min |
| Completed | 2026-03-19 |
| Tasks | 2 completed |
| Files modified | 4 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Button visible on machine detail | Pass | Sparkle icon + "KI-Analyse" in header next to Send Credit |
| AC-2: Clicking fetches and displays recommendations | Pass | Sheet opens, calls edge function, renders cards sorted by priority |
| AC-3: Loading and error states | Pass | Spinner + skeleton while loading; red error card on failure (verified with missing API key + billing error) |
| AC-4: Empty state | Pass | "No recommendations" message when array is empty |
| AC-5: i18n EN + DE | Pass | All labels translated; verified in German locale |

## Accomplishments

- `useInsights` composable with typed response, fetch, loading/error states, and pure helper functions
- AI Insights button integrated into machine detail header (visible to all users)
- Sheet overlay with priority-sorted recommendation cards, type badges, summary section, and generated timestamp
- 15 i18n keys added (9 machineDetail + 6 insights type labels) in both EN and DE

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `management-frontend/app/composables/useInsights.ts` | Created | Composable: types, fetch, loading/error, priority helpers |
| `management-frontend/app/pages/machines/[id].vue` | Modified | Added imports, button in header, Sheet component at end |
| `management-frontend/i18n/locales/en.json` | Modified | Added machineDetail.ai* + insights.* keys |
| `management-frontend/i18n/locales/de.json` | Modified | Added machineDetail.ai* + insights.* keys (German) |

## Deviations from Plan

### Auto-fixed Issues

**1. RPC `round(double precision, integer)` error**
- **Found during:** Testing AI Insights button
- **Issue:** `get_machine_insights_kpis` RPC used float literals (`100.0`, `7.0`) causing `double precision` result, but `round(double precision, int)` doesn't exist in PostgreSQL
- **Fix:** Changed to integer divisors (`100`, `7`) so PostgreSQL keeps `numeric` type
- **Files:** `Docker/supabase/migrations/20260317000000_machine_insights_rpc.sql`

**2. Missing UPDATE grant on companies table**
- **Found during:** Testing API key save in Settings
- **Issue:** `authenticated` role had SELECT + INSERT but no UPDATE grant — RLS policy existed but base permission was missing
- **Fix:** Added `GRANT UPDATE ON public.companies TO authenticated` to migration
- **Files:** `Docker/supabase/migrations/20260319000000_company_anthropic_key.sql`

**3. Anthropic JSON response parsing**
- **Found during:** First successful Anthropic API call
- **Issue:** Claude sometimes wraps JSON in markdown code fences; greedy regex fallback could grab trailing text
- **Fix:** Strip code fences first, then balanced-brace extraction as fallback
- **Files:** `Docker/supabase/functions/machine-insights/index.ts`

**4. Cleaner Anthropic error messages**
- **Found during:** Testing with insufficient API credits
- **Issue:** Raw `400 {"type":"error",...}` shown to user
- **Fix:** Extract clean `error.error.message` from Anthropic SDK errors
- **Files:** `Docker/supabase/functions/machine-insights/index.ts`

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 4 | Essential fixes for production readiness |
| Scope additions | 0 | — |
| Deferred | 0 | — |

## Next Phase Readiness

**Ready:**
- AI Insights feature complete end-to-end (Phase 01 RPC → Phase 02 edge function → Phase 03 UI)
- Milestone v1.1 ready for completion

**Concerns:**
- None

**Blockers:**
- None

---
*Phase: 03-insights-ui, Plan: 01*
*Completed: 2026-03-19*
