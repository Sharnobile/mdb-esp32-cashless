# Roadmap: mdb-esp32-cashless

## Overview

Extend the existing production vending machine telemetry system with AI-powered analytics, optimized warehouse picking workflows, tax-compliant sales reporting, GoBD-compliant cash book management, and a public-facing mobile storefront with cashless payment.

## Current Milestone

**Mobile Storefront (v1.7)**
Status: Complete
Phases: 2 of 2 complete

| Phase | Name | Plans | Status | Completed |
|-------|------|-------|--------|-----------|
| 14 | public-storefront | 1 | Complete | 2026-04-09 |
| 15 | mobile-payment | 2 | Complete | 2026-04-09 |

### Phase 14: public-storefront

Focus: Public machine page — Edge function `public-machine-data` (service_role, no auth), public Nuxt page `/m/[subdomain]` showing machine name, status, location, products grouped by category with stock levels, prices, availability badges, product images, and color-coded stock progress bars. Mobile-first responsive design, i18n (en/de).
Plans: 1 (14-01-PLAN.md) — Complete

### Phase 15: mobile-payment

Focus: Stripe payment integration — Per-company Stripe API keys, Stripe Payment Intent edge function, product selection + checkout UI on public page, Apple Pay / Google Pay via Stripe Payment Element, credit delivery to ESP32 via existing send-credit flow on successful payment, payment records.
**Note:** MDB slave device cannot force a vend — the flow is: web payment → credit to ESP32 → ESP32 presents credit to VMC → customer selects product on machine → VMC vends. Customer must physically interact with the machine after paying online.
Plans: 2 (15-01-PLAN.md, 15-02-PLAN.md) — Complete

## Completed Milestones

<details>
<summary>Kassenbuch (v1.6) — 2026-04-07 (2 phases)</summary>

| Phase | Name | Plans | Completed |
|-------|------|-------|-----------|
| 12 | cash-book-infrastructure | 1 | 2026-04-07 |
| 13 | cash-book-frontend | 2 | 2026-04-07 |

</details>

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
*Last updated: 2026-04-09 — Milestone v1.7 Mobile Storefront complete*
