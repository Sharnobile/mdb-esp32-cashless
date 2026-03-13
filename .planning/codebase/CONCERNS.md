# CONCERNS — management-frontend

> Technical debt, known issues, security, performance, and fragile areas

## Critical Issues

### Missing TypeScript Database Types
- **Impact**: High — Supabase client returns `never` for all queries
- **Details**: No `database.types.ts` generated. All query results manually cast with `as any` or inline type assertions (130+ occurrences across composables and pages)
- **Files**: `useMachines.ts:68`, `useWarehouse.ts:169`, `pages/devices/index.vue:59`, `useMachineTrays.ts:34,43,102`, `useActivityLog.ts:74-92`
- **Fix**: Run `supabase gen types typescript` to generate types

### N+1 Query Pattern in useMachines
- **Impact**: High — One query per machine for last sale, stats, paxcounter
- **Details**: `useMachines.ts:123-132` spawns `n` parallel queries for `n` machines via `Promise.all`. Should be a single join or aggregation query
- **Files**: `app/composables/useMachines.ts:123-132`

### Minimal Test Coverage
- **Impact**: High — Only 1 test file (`useMdbLog.test.ts`) for 16 composables
- **Missing tests for**: `useMachines` (complex stock calculation), `useWarehouse` (FIFO deduction), `useProducts` (image upload), `useMachineTrays` (debounced updates), `useNotifications`, `useActivityLog`, `useFirmware`
- **No integration tests** for any pages

## Security Concerns

### Cookie Security
- `nuxt.config.ts:32` — `secure: false` for auth cookies (intended for LAN dev but applies to all environments)
- Should be environment-aware

### Session Storage for Packing Lists
- `pages/machines/index.vue:164` — Refill packing data stored in plain `sessionStorage`
- Low risk but data is readable if session storage is accessible

### Console Logging in Production
- `useNotifications.ts` — 14+ `console.info/warn/error` calls revealing internal state
- `useAppResume.ts` — 3 `console.warn` calls
- `useMachines.ts:454`, `useFirmware.ts:124` — Additional `console.error` calls
- **Fix**: Gate behind `import.meta.dev` or remove

## Performance Issues

### Redundant Realtime Subscriptions
- `useMachines.ts:372-457` — Subscribes to `embeddeds`, `vendingMachine`, `sales`, and `machine_trays` with `event: '*'`
- Any change to any table triggers full `fetchMachines()` re-fetch (expensive parallel query batch)

### Inefficient Stock Calculation
- `useMachines.ts:215-316` — Two-pass loop with intermediate Maps and Sets for every machine on every fetch

### Missing Pagination
- `useActivityLog.ts:99` — `PAGE_SIZE = 50` hardcoded, loads all on first visit

## Error Handling Gaps

### Unhandled Promise Rejections
- `pages/index.vue:99-112` — `.then()` chain without `.catch()` on machine_trays product lookup
- `pages/index.vue:105-112` — Silent failure if tray query fails

### Silent Middleware Errors
- `middleware/auth.ts:28-34` — Catches org fetch error, silently redirects to `/onboarding/create-organization` without logging

### Realtime Subscription Errors
- `useMachines.ts:453-455` — Errors only logged to console, not exposed to UI
- `useActivityLog.ts:127-143` — Realtime channel has no error handler

### Timer/Cleanup Issues
- `useMachineTrays.ts:29-30` — `pendingStockTimers` Map never cleared on page unmount (potential memory leak)
- `useMachineTrays.ts:184-194` — If DB update fails, pending tray state not reset
- `useMachineTrays.ts:333` — `.subscribe()` called without checking if channel already active (double-subscribe risk)

## SSR/Hydration Concerns

### Supabase URL Client-Only Rewrite
- `plugins/supabase-url.client.ts:14-16` — URL rewritten from `127.0.0.1` to browser hostname on client only
- `middleware/auth.ts:19-21` — Must skip org fetch on SSR to avoid using raw URL
- **Risk**: Any SSR Supabase call before plugin runs will fail auth

### localStorage Access Without SSR Guard
- `useInstallPrompt.ts:50` — `localStorage.getItem()` called without `import.meta.server` guard
- Relies on `onMounted()` but no explicit protection

### Hydration Mismatch Risk
- `useNotifications.ts:54-61` — iOS detection in `onMounted()` could cause hydration mismatch if SSR renders differently

## Code Duplication

### Repeated Query Building
- `useActivityLog.ts:73-92` — `buildQuery()` duplicated between `fetchLogs()` and `fetchMore()`
- `useWarehouse.ts:508-522` and `535-548` — Identical transaction query building

### Triplicated Constants
- `PAGE_SIZE = 50` defined independently in `useWarehouse.ts:100`, `useMdbLog.ts:27`, `useActivityLog.ts:29`

### Repeated Error Message Pattern
- `err instanceof Error ? err.message : 'Generic message'` repeated across `machines/index.vue:78`, `products/index.vue:79`, `devices/index.vue:108`

## Hardcoded Values

| Value | Location | Description |
|-------|----------|-------------|
| `PAGE_SIZE = 50` | 3 composables | Should be shared constant |
| `700` ms debounce | `useMachineTrays.ts:193` | Stock update debounce |
| `10_000` ms timeout | `useNotifications.ts:113` | Permission timeout |
| `15_000` ms timeout | `useNotifications.ts:145` | Push test timeout |
| `30_000` ms | `useAppResume.ts:17` | Min background time |
| `http://127.0.0.1:54321` | `useProducts.ts:21` | Fallback Supabase URL |

## Accessibility

- No explicit `aria-label` on interactive elements in modals/forms
- Stock health status (`ok`, `low`, `critical`) indicated by color only — not distinguishable for colorblind users (`useMachines.ts:301`)
- Keyboard navigation not tested for pull-to-refresh, packing checklist, modals

## Unused/Legacy Files

- `management-frontend/pages/` — Old Nuxt 2 directory, unused (all pages in `app/pages/`)
- Should be deleted to avoid confusion

## Dependency Concerns

- PWA module disabled (`nuxt.config.ts:70`, `disable: true`) due to Workbox iOS issues — plain SW manually maintained
- `@nuxtjs/supabase: ^2.0.3` — Permissive semver range could receive breaking changes
- `useNotifications.ts:110-114` — `Promise.race()` catch silently returns `'default'`, masking actual permission state

## Summary Priority Matrix

| Priority | Issue | Category |
|----------|-------|----------|
| P0 | Missing database.types.ts (130+ unsafe casts) | Types |
| P0 | Only 1/16 composables tested | Testing |
| P1 | N+1 queries in useMachines | Performance |
| P1 | Unhandled promises in dashboard | Errors |
| P1 | Redundant realtime re-fetches | Performance |
| P2 | Console logs in production | Security |
| P2 | Cookie secure:false in all envs | Security |
| P2 | Timer memory leaks in useMachineTrays | Memory |
| P2 | SSR/hydration risks | Stability |
| P3 | Hardcoded constants | Maintainability |
| P3 | Code duplication | Maintainability |
| P3 | Accessibility gaps | A11y |
| P3 | Unused pages/ directory | Cleanup |
