# Roadmap: mdb-esp32-cashless

## Overview

Extend the existing production vending machine telemetry system with AI-powered analytics, optimized warehouse picking workflows, tax-compliant sales reporting, and GoBD-compliant cash book management.

## Current Milestone

**Kassenbuch (v1.6)**
Status: Complete
Phases: 2 of 2 complete

| Phase | Name | Plans | Status | Completed |
|-------|------|-------|--------|-----------|
| 12 | cash-book-infrastructure | 1 | Complete | 2026-04-07 |
| 13 | cash-book-frontend | 2 | Complete | 2026-04-07 |

### Phase 12: cash-book-infrastructure

Focus: DB + Backend — `cash_books` Tabelle (pro Automat, Aktivierungsdatum, Anfangsbestand), `cash_book_entries` Tabelle (unveränderliche GoBD-konforme Einträge mit Hash-Kette), RLS-Policies (kein DELETE/UPDATE auf Einträge), RPC für theoretischen Kassenstand (Bargeldverkäufe seit letzter Entnahme), sequentielle Nummerierung
Plans: TBD (defined during /paul:plan)

### Phase 13: cash-book-frontend

Focus: UI — Kassenbuch-Seite pro Automat, KPI-Karten (aktueller Stand, Gesamtentnahmen, Korrekturen, Integritätsprüfung), Entnahme-Dialog mit Soll/Ist-Vergleich (theoretischer vs. gezählter Betrag, Differenz-Anzeige), Korrektur-Dialog, Auszahlung auf Bankkonto, GoBD-Konformitäts-Badge, PDF-Export, Zeitraumfilter, i18n (de/en)
Plans: TBD (defined during /paul:plan)

## Completed Milestones

<details>
<summary>Steuer-Berichte (v1.5) — 2026-04-05 (3 phases)</summary>

| Phase | Name | Plans | Completed |
|-------|------|-------|-----------|
| 09 | tax-infrastructure | 2 | 2026-04-05 |
| 10 | tax-backfill-validation | 1 | 2026-04-05 |
| 11 | tax-reports-export | 1 | 2026-04-05 |

</details>

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
*Last updated: 2026-04-07 — Milestone v1.6 Kassenbuch complete*
