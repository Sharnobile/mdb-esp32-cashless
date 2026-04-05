# Roadmap: mdb-esp32-cashless

## Overview

Extend the existing production vending machine telemetry system with AI-powered analytics, optimized warehouse picking workflows, and tax-compliant sales reporting.

## Current Milestone

**Steuer-Berichte (v1.5)**
Status: Complete
Phases: 3 of 3 complete

| Phase | Name | Plans | Status | Completed |
|-------|------|-------|--------|-----------|
| 09 | tax-infrastructure | 2 | Complete | 2026-04-05 |
| 10 | tax-backfill-validation | 1 | Complete | 2026-04-05 |
| 11 | tax-reports-export | 1 | Complete | 2026-04-05 |

### Phase 09: tax-infrastructure

Focus: DB + Backend — `tax_classes`, `tax_rates`, `system_tax_rates` Tabellen + RLS; `tax_class_id` auf Kategorie/Produkt; `country_code` auf Company/Machine; Sales-Stamp-Trigger; DE/AT Rates seeden; UI für Steuerklassen/Sätze pflegen + Kategorie-Zuweisung + Land-Auswahl
Plans: TBD (defined during /paul:plan)

### Phase 10: tax-backfill-validation

Focus: Datenbereinigung — Backfill historischer Sales (nachträglich stempeln); Export-Seite Validierung (Blocker wenn Steuerklassen fehlen); Hinweis-Banner
Plans: TBD (defined during /paul:plan)

### Phase 11: tax-reports-export

Focus: Export-Funktionalität — Report-Seite mit Zeitraum-Auswahl; DATEV Buchungsstapel CSV-Export; Einfacher CSV-Export; Vorschau-Tabelle
Plans: TBD (defined during /paul:plan)

## Completed Milestones

<details>
<summary>Enhanced AI Insights (v1.4) — 2026-03-19 (1 phase)</summary>

| Phase | Name | Plans | Completed |
|-------|------|-------|-----------|
| 08 | enhanced-insights | 1 | 2026-03-19 |

</details>

<details>
<summary>AI Insights & Optimization (v1.1) — 2026-03-19 (3 phases)</summary>

| Phase | Name | Plans | Completed |
|-------|------|-------|-----------|
| 01 | data-aggregation | 1 | 2026-03-18 |
| 02 | insights-edge-function | 1 | 2026-03-19 |
| 03 | insights-ui | 1 | 2026-03-19 |

</details>

<details>
<summary>Warehouse Picking Optimization (v1.2) — 2026-03-18 (2 phases)</summary>

| Phase | Name | Plans | Completed |
|-------|------|-------|-----------|
| 04 | warehouse-product-positions | 1 | 2026-03-18 |
| 05 | sorted-picklist | 1 | 2026-03-18 |

</details>

<details>
<summary>Refill Tour Optimizations (v1.3) — 2026-03-19 (2 phases)</summary>

| Phase | Name | Plans | Completed |
|-------|------|-------|-----------|
| 06 | custom-packing-quantities | 1 | 2026-03-19 |
| 07 | tour-history | 1 | 2026-03-19 |

</details>

---
*Roadmap created: 2026-03-17*
*Last updated: 2026-04-05 — Milestone v1.5 Steuer-Berichte created*
