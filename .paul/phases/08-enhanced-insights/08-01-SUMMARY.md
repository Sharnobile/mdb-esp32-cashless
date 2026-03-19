---
phase: 08-enhanced-insights
plan: 01
subsystem: api, ui, database
tags: [anthropic, claude, ai-insights, caching, trends, dow, hourly, company-insights, history]

requires:
  - phase: 02-insights-edge-function
    provides: machine-insights edge function, per-company API key, V1 RPC
provides:
  - Enhanced V2 RPC with DOW/hourly distributions, warehouse stock, trends
  - Company-wide insights RPC (get_company_insights_kpis)
  - Insights history table (machine_insights_history)
  - Locale-aware caching
  - Company insights on dashboard with collapsible card + history
  - Machine insights history in sheet
  - 4 new recommendation types (pricing_strategy, cross_selling, peak_hour_strategy, day_pattern)
affects: [future AI features, dashboard enhancements]

tech-stack:
  added: []
  patterns: [history-from-DB on mount instead of API call, collapsible dashboard cards]

key-files:
  created:
    - Docker/supabase/migrations/20260319100000_enhanced_insights.sql
    - Docker/supabase/migrations/20260320000000_insights_v2_enhancements.sql
  modified:
    - Docker/supabase/functions/machine-insights/index.ts
    - management-frontend/app/composables/useInsights.ts
    - management-frontend/app/pages/machines/[id].vue
    - management-frontend/app/pages/index.vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Current machine stock excluded from AI analysis (transient snapshot)"
  - "Company insights cached with machine_id=company_id convention"
  - "History loaded from DB on mount, no auto AI request"
  - "Fleet insights card collapsed by default"
  - "Locale-aware cache (EN/DE stored separately)"

patterns-established:
  - "Load last result from history table on mount instead of triggering API call"
  - "Collapsible insight cards with chevron toggle"
  - "type parameter on edge function for machine/company/history routing"

duration: ~90min
completed: 2026-03-19
---

# Phase 08 Plan 01: Enhanced AI Insights Summary

**V2 RPC with DOW/hourly/trends, company-wide insights, history persistence, caching, and 4 new recommendation types — no misleading stock warnings.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~90min |
| Completed | 2026-03-19 |
| Tasks | 3 planned + significant iteration |
| Files modified | 8 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: RPC includes warehouse stock and trend comparison | Pass | V2 RPC returns warehouse_stock, trends, DOW + hourly distributions |
| AC-2: Insights cached and returned from cache when fresh | Pass | 6h TTL, locale-aware, force_refresh support |
| AC-3: New recommendation types supported | Pass | pricing_strategy, cross_selling, peak_hour_strategy, day_pattern |
| AC-4: Current stock not flagged as critical | Pass | Removed from V2 RPC output, explicit prompt instruction |
| AC-5: Trend comparison visible in UI | Pass | Trend badges on machine + company insights |

## Accomplishments

- V2 RPC enhanced with day-of-week distribution, hourly distribution, peak hours, warehouse stock, and period-over-period trends
- New `get_company_insights_kpis` RPC aggregating across all machines (top/bottom, DOW, hourly, trends)
- `machine_insights_history` table with auto-cleanup trigger (20 entries per scope)
- Edge function supports 3 modes: `type=machine`, `type=company`, `type=history`
- Dashboard has collapsible Fleet AI Insights card with history, loaded from DB (no auto API call)
- Machine detail insights sheet includes expandable history section
- All responses localized (EN/DE) via prompt instruction

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/migrations/20260319100000_enhanced_insights.sql` | Modified | Fixed expiry_date→expiration_date column name |
| `Docker/supabase/migrations/20260320000000_insights_v2_enhancements.sql` | Created | History table, cache locale, V2 DOW/hourly, company RPC |
| `Docker/supabase/functions/machine-insights/index.ts` | Modified | Refactored: type routing, company prompt, history writes, locale cache, improved JSON parser |
| `management-frontend/app/composables/useInsights.ts` | Modified | Added history, company types, fetchHistory, fetchCompanyInsights, new rec types |
| `management-frontend/app/pages/machines/[id].vue` | Modified | Insights history section, refresh button moved to footer |
| `management-frontend/app/pages/index.vue` | Modified | Fleet insights card (collapsible, loads from history, no auto AI call) |
| `management-frontend/i18n/locales/en.json` | Modified | 11 new keys (insights types, history, company insights) |
| `management-frontend/i18n/locales/de.json` | Modified | 11 new keys (German translations) |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Auto-fixed | 3 | Essential fixes |
| Scope additions | 3 | User-requested during execution |

**Total impact:** Significant scope expansion beyond original plan — added DOW/hourly, company insights, history persistence. All user-requested.

### Auto-fixed Issues

**1. expiry_date column name**
- Found during: Task 1 (migration)
- Issue: Used `expiry_date` but actual column is `expiration_date`
- Fix: Corrected in migration SQL

**2. JSON parsing failures on production**
- Found during: Task 2 (edge function)
- Issue: Claude sometimes wraps response in markdown fences; regex only caught line-start/end fences
- Fix: Global fence removal + string-aware brace matching

**3. Anthropic SDK import failure on self-hosted edge runtime**
- Found during: deployment
- Issue: `npm:@anthropic-ai/sdk` and `esm.sh` approaches both fail in supabase edge-runtime
- Fix: Direct `fetch()` to Anthropic API (no SDK)

### Scope Additions (user-requested)

- **DOW + hourly distributions** in V2 RPC (Phase 09 scope, pulled in)
- **Company-wide insights** RPC + edge function branch + dashboard UI (Phase 10 scope, pulled in)
- **History persistence** with DB-backed loading on mount (replaced localStorage approach)
- **Fleet card collapsed by default**, loads from history not API

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Load from history on mount, not cache/API | User wanted no Anthropic cost on page reload, works across devices | Dashboard reads DB history only |
| Fleet card collapsed by default | Saves dashboard space | User clicks to expand |
| Company cache uses machine_id=company_id | Reuses existing cache table without schema changes | Convention documented in code |
| Locale stored in cache unique constraint | EN/DE responses cached separately | Prevents wrong-language cache hits |

## Next Phase Readiness

**Ready:**
- All backend infrastructure in place (RPCs, cache, history, edge function)
- Frontend fully integrated (machine + company insights)
- i18n complete for EN + DE

**Concerns:**
- Prod deployment needs manual migration application (supabase migration up won't re-run modified files)

**Blockers:**
- None

---
*Phase: 08-enhanced-insights, Plan: 01*
*Completed: 2026-03-19*
