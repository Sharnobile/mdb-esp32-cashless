# Milestones

Completed milestone log for this project.

| Milestone | Completed | Duration | Stats |
|-----------|-----------|----------|-------|
| AI Insights & Optimization (v1.1) | 2026-03-19 | 2 days | 3 phases, 3 plans |
| Warehouse Picking Optimization (v1.2) | 2026-03-18 | 1 day | 2 phases, 2 plans |

---

## AI Insights & Optimization (v1.1)

**Completed:** 2026-03-19
**Duration:** 2 days (2026-03-17 → 2026-03-19)

### Stats

| Metric | Value |
|--------|-------|
| Phases | 3 |
| Plans | 3 |
| Files changed | 15 |

### Key Accomplishments

- `get_machine_insights_kpis` PostgreSQL RPC function for pre-aggregated per-machine KPIs (sell-through, dead stock, refill prediction, conversion rate)
- `machine-insights` Supabase edge function with dual auth (JWT + API key), Anthropic Claude haiku integration, structured JSON recommendations
- Per-company Anthropic API key stored in `companies` table with admin settings UI
- AI Insights button + Sheet overlay on machine detail page with priority-sorted recommendations, type badges, summary, and loading/error/empty states
- Full i18n support (EN + DE) across all AI Insights UI

### Key Decisions

| Decision | Rationale |
|----------|-----------|
| Pre-aggregated KPIs in SQL (not app layer) | Reduces Claude API token usage, enforces tenancy at DB level |
| `security definer` + manual `p_company_id` check | Service role client bypasses RLS — manual check is the tenancy gate |
| Per-company API key (not global env var) | Multi-tenant friendly, each company manages their own Anthropic key |
| `claude-haiku-4-5` model | Fast, cheap, well-suited for structured JSON output |
| Sheet overlay (not Dialog) for recommendations | Better for scrollable content on mobile |

---

## Warehouse Picking Optimization (v1.2)

**Completed:** 2026-03-18
**Duration:** 1 day

### Stats

| Metric | Value |
|--------|-------|
| Phases | 2 |
| Plans | 2 |
| Files changed | ~10 |

### Key Accomplishments

- `warehouse_product_positions` table for per-warehouse product ordering with location labels
- Button-based reordering (up/down arrows) for mobile compatibility
- Position-sorted pick lists in refill wizard with per-machine and combined picking modes
- Combined deficit capped by warehouse total stock

### Key Decisions

| Decision | Rationale |
|----------|-----------|
| Denormalized `company_id` on positions table | Matches `warehouse_stock_batches` RLS pattern |
| Button-based reordering (not drag-and-drop) | Mobile compatibility |
| Computed sort layer over raw machines | Zero risk to existing logic |

---
