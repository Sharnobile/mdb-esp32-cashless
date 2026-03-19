---
phase: 02-insights-edge-function
plan: 01
subsystem: api
tags: [anthropic, claude, edge-function, supabase, ai-insights]

requires:
  - phase: 01-data-aggregation
    provides: get_machine_insights_kpis RPC function
provides:
  - machine-insights edge function (per-company Anthropic key)
  - AI Insights settings UI card (admin-only API key management)
  - companies.anthropic_api_key column + admin UPDATE policy
affects: [03-insights-ui]

tech-stack:
  added: ["@anthropic-ai/sdk (npm)"]
  patterns: [per-company API key storage, admin-only company settings]

key-files:
  created:
    - Docker/supabase/functions/machine-insights/index.ts
    - Docker/supabase/functions/machine-insights/deno.json
    - Docker/supabase/migrations/20260319000000_company_anthropic_key.sql
  modified:
    - Docker/supabase/config.toml
    - management-frontend/app/pages/settings/index.vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Per-company API key instead of global env var — each company manages their own Anthropic key"
  - "Key stored in companies.anthropic_api_key (plaintext) — acceptable since RLS restricts to company members"
  - "Admin UPDATE policy on companies table — needed for settings page"

patterns-established:
  - "Per-company settings pattern: nullable column on companies + admin UPDATE policy + settings UI"

duration: ~30min
completed: 2026-03-19
---

# Phase 02 Plan 01: machine-insights Edge Function Summary

**Supabase edge function with dual auth, per-company Anthropic API key, Claude haiku for structured JSON recommendations, plus admin settings UI for key management.**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~30min |
| Completed | 2026-03-19 |
| Tasks | 2 planned + 1 refactor (per-company key) |
| Files modified | 10 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Structured recommendations | Pass | Returns `{ generated_at, period_days, machine, recommendations[], summary }` |
| AC-2: Dual auth (JWT + API key) | Pass | Matches send-credit pattern exactly |
| AC-3: Company isolation | Pass | RPC enforces via `p_company_id` parameter |
| AC-4: Missing key returns error | Pass (modified) | Now returns 400 "No Anthropic API key configured for this organization" instead of 500 — key is per-company, not global |
| AC-5: Config files updated | Pass (modified) | `config.toml` has `[functions.machine-insights]` block; global `ANTHROPIC_API_KEY` env var removed from all config files (replaced by DB column) |

## Accomplishments

- Edge function created with dual auth, RPC integration, and Anthropic `claude-haiku-4-5` API call
- Switched from global env var to per-company API key stored in `companies.anthropic_api_key`
- Admin-only "AI Insights" settings card with masked key display, save/update/remove
- i18n support in both EN and DE

## Files Created/Modified

| File | Change | Purpose |
|------|--------|---------|
| `Docker/supabase/functions/machine-insights/index.ts` | Created | Edge function: auth → company key lookup → RPC → Anthropic → JSON |
| `Docker/supabase/functions/machine-insights/deno.json` | Created | Import map for supabase-js + anthropic SDK |
| `Docker/supabase/migrations/20260319000000_company_anthropic_key.sql` | Created | Adds `anthropic_api_key` to companies + admin UPDATE policy |
| `Docker/supabase/config.toml` | Modified | Added `[functions.machine-insights]` block; removed global `ANTHROPIC_API_KEY` from secrets |
| `Docker/.env.example` | Modified | Removed `ANTHROPIC_API_KEY` line |
| `Docker/supabase/.env.example` | Modified | Removed `ANTHROPIC_API_KEY` line |
| `Docker/setup.sh` | Modified | Removed ANTHROPIC_API_KEY warning + .env write blocks |
| `Docker/update.sh` | Modified | Removed ANTHROPIC_API_KEY check block |
| `management-frontend/app/pages/settings/index.vue` | Modified | Added AI Insights card (admin-only key management) |
| `management-frontend/i18n/locales/en.json` | Modified | Added 10 i18n keys for AI Insights settings |
| `management-frontend/i18n/locales/de.json` | Modified | Added 10 i18n keys (German) |

## Decisions Made

| Decision | Rationale | Impact |
|----------|-----------|--------|
| Per-company API key (not global env var) | Each company manages their own Anthropic key — multi-tenant friendly, no shared cost | Edge function reads from DB instead of env; companies table gets new column |
| Plaintext storage in companies table | Existing pattern (passkey in embeddeds is also plaintext); RLS restricts to company members | Viewers can technically read key via RLS SELECT — acceptable for trusted team members |
| Admin-only UPDATE policy on companies | Only admins should manage company settings | New RLS policy `companies_update_admin` created |
| Settings UI (not separate page) | API key management is a simple admin setting, doesn't warrant its own page | Added as card in existing settings page |

## Deviations from Plan

### Summary

| Type | Count | Impact |
|------|-------|--------|
| Scope change | 1 | Per-company key replaces global env var — improves multi-tenancy |
| Auto-fixed | 0 | — |
| Deferred | 0 | — |

**Total impact:** Architectural improvement — per-company key is strictly better for multi-tenant SaaS.

### Scope Change: Per-Company API Key

- **Original plan:** Global `ANTHROPIC_API_KEY` env var read by edge function
- **Actual:** Per-company key stored in `companies.anthropic_api_key`, read from DB at runtime
- **Reason:** User requested per-company keys for multi-tenant flexibility
- **Files added:** Migration, settings UI, i18n keys
- **Files changed:** Edge function (DB lookup instead of env), all config files (removed global key)

## Function Signature

**Endpoint:** `POST /functions/v1/machine-insights`

**Request:**
```json
{ "machine_id": "uuid", "days": 30 }
```

**Response (200):**
```json
{
  "generated_at": "ISO timestamp",
  "period_days": 30,
  "machine": { "id": "uuid", "name": "Machine Name" },
  "recommendations": [
    {
      "type": "product_swap | capacity_increase | remove_slot | refill_optimization | conversion_alert | general",
      "priority": "high | medium | low",
      "title": "Short actionable title",
      "detail": "Detail with numbers",
      "item_number": 3
    }
  ],
  "summary": "Narrative paragraph..."
}
```

**Errors:** 401 (no auth), 400 (missing machine_id or no API key for company), 404 (machine not found), 500 (RPC/API error)

## Next Phase Readiness

**Ready:**
- Edge function fully implemented and callable
- Settings UI for API key management deployed
- Phase 03 (insights-ui) can call `supabase.functions.invoke('machine-insights', { body: { machine_id, days } })`

**Concerns:**
- None

**Blockers:**
- None

---
*Phase: 02-insights-edge-function, Plan: 01*
*Completed: 2026-03-19*
