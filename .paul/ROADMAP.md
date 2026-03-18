# Roadmap: mdb-esp32-cashless

## Overview

Extend the existing production vending machine telemetry system with AI-powered analytics to help operators optimize product placement, reduce refill frequency, and maximize revenue per machine.

## Current Milestone

**AI Insights & Optimization** (v1.1)
Status: In progress
Phases: 1 of 3 complete

## Phases

| Phase | Name | Plans | Status | Completed |
|-------|------|-------|--------|-----------|
| 01 | data-aggregation | 1 | ✅ Complete | 2026-03-18 |
| 02 | insights-edge-function | 1 | Not started | - |
| 03 | insights-ui | 1 | Not started | - |

## Phase Details

### Phase 01: data-aggregation
**Goal:** PostgreSQL RPC function `get_machine_insights_kpis()` that returns pre-aggregated KPI data per machine — sales velocity per tray, sell-through rate, dead stock detection, paxcounter conversion rate, and refill history — without exposing raw rows to the edge function.
**Depends on:** Nothing (first phase)
**Output:** Migration file with RPC callable by Phase 02 edge function

### Phase 02: insights-edge-function
**Goal:** `machine-insights` Supabase edge function that calls the Phase 01 RPC, builds a structured prompt, calls Claude API (Anthropic), and returns JSON recommendations. Add `ANTHROPIC_API_KEY` to all required env config files (Docker + local dev).
**Depends on:** Phase 01 (needs RPC function name + return shape)
**Output:** Edge function deployable to both local dev and production Docker

### Phase 03: insights-ui
**Goal:** `useInsights` composable + "AI Insights" button on `/machines/[id]` page that calls the Phase 02 edge function and displays structured recommendations in a sheet/modal (product swaps, capacity suggestions, refill optimization).
**Depends on:** Phase 02 (needs edge function endpoint + response schema)
**Output:** Working UI operators can use to get AI recommendations per machine

---
*Roadmap created: 2026-03-17*
*Last updated: 2026-03-17*
