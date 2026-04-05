---
phase: 11-tax-reports-export
plan: 01
subsystem: ui
tags: [nuxt, vue, composable, csv, datev, export, reports, i18n]

requires:
  - phase: 09-tax-infrastructure
    provides: tax_classes, tax_rates, sales tax columns, useTaxSettings
  - phase: 10-tax-backfill-validation
    provides: taxReadiness computed for export gating
provides:
  - /reports page with date range picker, preview table, VAT breakdown
  - Simple CSV export (UTF-8 BOM, German locale)
  - DATEV EXTF Buchungsstapel export (Windows-1252, v700, SKR03)
  - Payment method filter toggles
  - Sidebar navigation link
affects: []

tech-stack:
  added: []
  patterns: [client-side CSV generation, Windows-1252 encoding, DATEV EXTF format]

key-files:
  created:
    - management-frontend/app/composables/useReports.ts
    - management-frontend/app/pages/reports/index.vue
  modified:
    - management-frontend/app/components/AppSidebar.vue
    - management-frontend/i18n/locales/en.json
    - management-frontend/i18n/locales/de.json

key-decisions:
  - "Client-side CSV generation — no server-side export needed"
  - "DATEV accounts hardcoded SKR03 (10000/8400/8300) — configurable later"
  - "Payment filters affect KPIs, VAT breakdown, table, AND exports"
  - "taxDataLoaded guard prevents false-positive readiness blocker on fresh page load"

patterns-established:
  - "useReports pattern: filteredSales computed from channelFilters for reactive filtering"
  - "vatBreakdown: grouped by tax_rate_snapshot, sorted rate DESC"
  - "toWindows1252(): best-effort encoding for DATEV compatibility"

duration: 30min
started: 2026-04-05
completed: 2026-04-05
---

# Phase 11 Plan 01: Tax Reports Export

**Complete reports page with date range selection, payment method filters, VAT breakdown table, and dual CSV export (simple + DATEV Buchungsstapel).**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~30min |
| Tasks | 3 completed (2 auto + 1 checkpoint) |
| Files created | 2 |
| Files modified | 3 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Reports page with date range | Pass | Presets: This month, Last month, Quarter, Year |
| AC-2: Tax readiness blocker | Pass | Guards with taxDataLoaded to prevent false positives |
| AC-3: Simple CSV export | Pass | UTF-8 BOM, semicolons, German decimals |
| AC-4: DATEV export | Pass | EXTF v700, Windows-1252, BU-Schlüssel 8/9 |
| AC-5: Navigation integration | Pass | Sidebar Operations group, IconFileSpreadsheet |

## Accomplishments

- `useReports` composable: data fetching with machine+tray+product joins, dual CSV generation, payment filters, VAT breakdown, summary KPIs
- `/reports` page: date range picker with presets, payment method toggle buttons, 5 KPI cards (gross, count, avg, tax, net), VAT breakdown table with per-rate totals, scrollable sales detail table
- DATEV EXTF Buchungsstapel: correct header format, BU-Schlüssel mapping (9=19%, 8=7%), SKR03 accounts, Windows-1252 encoding
- Simple CSV: German locale formatting, UTF-8 BOM for Excel
- Payment filters: toggle Cash/Cashless/Card — affects all views + exports
- Sidebar link with IconFileSpreadsheet icon

## Deviations from Plan

### Enhancements (User Requested)
- **Payment method filter toggles** — toggle buttons to filter by Cash/Cashless/Card, affects all computations
- **MwSt.-Aufschlüsselung** — VAT breakdown table grouped by tax rate with Brutto/Netto/MwSt./Count
- **Average per sale KPI** — additional summary card
- **filteredSales** — all exports use filtered data, not raw

### Fixes During Checkpoint
- **taxDataLoaded guard** — prevented false readiness blocker on fresh /reports page load (tax data not yet fetched)

---
*Phase: 11-tax-reports-export, Plan: 01*
*Completed: 2026-04-05*
