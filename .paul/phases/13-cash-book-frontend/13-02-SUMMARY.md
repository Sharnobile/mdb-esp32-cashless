---
phase: 13-cash-book-frontend
plan: 02
subsystem: ui
tags: [nuxt, vue, jspdf, dialogs, gobd, kassenbuch]

requires:
  - phase: 13-cash-book-frontend
    provides: useCashBook composable, /cash-book page shell
provides:
  - Withdrawal dialog with Soll/Ist comparison
  - Correction, payout, reversal dialogs
  - PDF export with GoBD footer
affects: []

tech-stack:
  added: [jspdf, jspdf-autotable]
  patterns: [dynamic import for client-only libs, ssr false for data pages]

key-files:
  modified:
    - management-frontend/app/pages/cash-book/index.vue
    - management-frontend/i18n/locales/de.json
    - management-frontend/i18n/locales/en.json
    - management-frontend/package.json

key-decisions:
  - "Withdrawal = POSITIVE for Barkasse (cash collected from machine INTO cash register)"
  - "Payout = NEGATIVE (cash going OUT to bank)"
  - "No auto-correction after withdrawal — difference is informational only"
  - "jspdf via dynamic import (client-only, crashes SSR)"
  - "Page uses ssr: false to avoid SSR component resolution issues"

patterns-established:
  - "Dynamic import for browser-only libraries in Nuxt pages"
  - "ssr: false on data-heavy pages with browser-only deps"

duration: 20min
started: 2026-04-07T23:00:00+02:00
completed: 2026-04-07T23:20:00+02:00
---

# Phase 13 Plan 02: Entry Dialogs + PDF Export Summary

**Withdrawal/correction/payout/reversal dialogs with Soll/Ist comparison and GoBD-compliant PDF export using jspdf**

## Performance

| Metric | Value |
|--------|-------|
| Duration | ~20min |
| Tasks | 3 completed (incl. checkpoint) |
| Files modified | 4 |

## Acceptance Criteria Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| AC-1: Withdrawal with Soll/Ist | Pass | Shows expected cash in machines, counted amount, difference |
| AC-2: Correction dialog | Pass | Positive/negative amount with description |
| AC-3: Payout dialog | Pass | Shows current balance, negates amount |
| AC-4: Reversal (Storno) | Pass | Confirmation dialog, marks original as reversed |
| AC-5: PDF export | Pass | jspdf + autotable, GoBD footer with hash |

## Deviations from Plan

### Auto-fixed Issues

**1. Toast library not available**
- Carried forward from Plan 01, inline banners used

**2. jsPDF SSR crash**
- Top-level import crashed SSR with "Unexpected token ':'"
- Fixed: dynamic import inside exportPdf function

**3. SSR component resolution error**
- "Cannot read properties of null (reading 'ce')" during SSR
- Fixed: `definePageMeta({ ssr: false })`

**4. Cash flow sign inversion**
- Withdrawal was negative (wrong), should be positive (cash INTO Barkasse)
- Theoretical cash comparison used wrong field (theoretical_balance vs cash_sales_since)
- Auto-correction offer after withdrawal was fundamentally broken (would double-count)
- Fixed: withdrawal = +counted, comparison uses cash_sales_since, auto-correction removed

**5. npm install failed on Node v12**
- Used nvm to switch to Node v24 for installation

## Next Phase Readiness

**Ready:** Complete Kassenbuch feature delivered

**Blockers:** None

---
*Phase: 13-cash-book-frontend, Plan: 02*
*Completed: 2026-04-07*
