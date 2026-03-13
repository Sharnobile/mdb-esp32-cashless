# Architecture

**Analysis Date:** 2026-03-13

## Pattern Overview

**Overall:** Nuxt 4 server-side rendering (SSR) with client-side composition pattern. Multi-tenant SaaS dashboard with Supabase backend integration, real-time updates via Postgres Change Data Capture (CDC), and Supabase edge functions for authentication and business logic.

**Key Characteristics:**
- Nuxt 4 app directory structure with file-based routing (`app/pages/` convention)
- Composable-based state management using Vue 3 Composition API + `useState()` for SSR hydration
- Real-time Postgres subscriptions via Supabase for live data updates (dashboard, machine status, tray stock)
- Edge function calls via `supabase.functions.invoke()` for auth-required operations (org management, credit transfer, OTA)
- Service Worker (plain `/sw.js`, no Workbox) for web push notifications only
- Tailwind CSS 4 + shadcn-nuxt for UI components
- TypeScript for type safety, though database types are manually cast (no generated types)
- Multi-language support via `@nuxtjs/i18n` (English, German)
- Progressive Web App (PWA) with offline capability and install prompts

## Layers

**Presentation (UI Components):**
- Purpose: Render pages and interactive elements; handle user input and display data
- Location: `app/components/`, `app/pages/`, `app/layouts/`
- Contains: Vue SFC components (`.vue` files), shadcn-nuxt primitives (buttons, cards, modals), page-level components (DashboardMachineList, SectionCards, ChartAreaInteractive)
- Depends on: Composables (via `<script setup>` injection), Vue Router, Vue I18n, Unovis charting
- Used by: End users via browser

**Composables (Business Logic & Data Fetching):**
- Purpose: Encapsulate Supabase queries, Postgres subscriptions, edge function calls, and state management
- Location: `app/composables/`
- Contains: 17+ composables (`useOrganization`, `useMachines`, `useWarehouse`, `useProducts`, `useMachineTrays`, `useFirmware`, `useNotifications`, `useActivityLog`, `useMdbLog`, `useImportProducts`, `useAppResume`, `useTheme`, `usePullToRefresh`, `useInstallPrompt`, `useAppUpdate`, `useNotifications`, `useProductImageSearch`)
- Depends on: Supabase client (`useSupabaseClient()`), Vue composition primitives (`ref`, `useState`, `computed`, `watch`)
- Used by: Page components via script setup

**Middleware & Plugins:**
- Purpose: Route protection, URL rewriting, service worker registration, plugin initialization
- Location: `app/middleware/`, `app/plugins/`
- Contains:
  - `auth.ts` middleware: Enforces authentication on protected routes, checks organization membership, redirects to login/onboarding
  - `supabase-url.client.ts` plugin: Rewrites Supabase URL from `127.0.0.1` to actual browser hostname for LAN access (critical for iOS PWA + ESP32 device access)
  - `register-sw.client.ts` plugin: Service worker registration with cache-busting
- Depends on: Nuxt routing, Supabase client
- Used by: Nuxt framework (auto-invoked on route changes and app startup)

**Layouts & Shell:**
- Purpose: Provide consistent header, sidebar, bottom tab bar, and page wrapper
- Location: `app/layouts/`
- Contains:
  - `default.vue`: Main app layout with SidebarProvider, AppSidebar, SiteHeader, PullToRefresh, BottomTabBar; shows update banner and PWA install prompt
  - `blank.vue`: Minimal layout (no sidebar) for auth pages
- Depends on: Components (AppSidebar, SiteHeader, BottomTabBar, PullToRefresh)
- Used by: Pages via layout auto-routing

**Entry Points:**
- Location: `app/app.vue`, `nuxt.config.ts`
- Purpose: Root layout wrapper (`<NuxtLayout><NuxtPage></NuxtLayout>`) and Nuxt configuration

## Data Flow

**Dashboard Load Flow:**

1. User navigates to `/` (protected route)
2. `auth` middleware runs:
   - Checks `useSupabaseUser()` — if null, redirects to `/auth/login`
   - Skips org fetch on SSR (URL rewrite is client-side only)
   - On client, calls `fetchOrganization()` from `useOrganization()` → invokes `get-my-organization` edge function
   - If no organization exists, redirects to `/onboarding/create-organization`
3. Page component (`app/pages/index.vue`) mounts:
   - `onMounted()` calls `loadDashboard()` which:
     - Fetches KPI aggregates (today/week/month sales via batch SQL queries)
     - Fetches machine status, stock health, activity log in parallel via Supabase
     - Subscribes to Postgres CDC on `sales`, `embeddeds`, `vendingMachine` tables for real-time updates
4. Real-time channel listens for:
   - `INSERT` on `sales` table → updates KPIs, machine revenue cards, activity feed
   - `UPDATE` on `embeddeds` table → updates machine status badge (online/offline)
   - `UPDATE` on `vendingMachine` table → updates machine metadata
5. On app resume from background (`useAppResume()`), dashboard re-fetches all data

**Machine Detail Page Load Flow:**

1. User navigates to `/machines/[id]`
2. `auth` middleware validates user + organization
3. Page component mounts:
   - Fetches `vendingMachine` by ID with `embeddeds` join (device status, firmware version, mdb_diagnostics)
   - Batch-fetches in parallel:
     - `machine_trays` (inventory slots) with product names
     - 30-day `sales` history (product image URLs injected client-side)
     - MDB logs from `mdb_log` table (state-change diagnostics)
   - Subscribes to `machine_trays` realtime updates for instant stock changes
   - Subscribes to `mdb_log` realtime for firmware diagnostics
4. User actions:
   - Edit tray stock → `adjustStockDebounced()` in `useMachineTrays` waits 500ms, then calls DB function `update_machine_tray_stock()`
   - Refill trays from warehouse → calls `deductForRefill()` edge function which deducts from warehouse FIFO batches
   - Send credit → calls `send-credit` edge function to publish XOR-encrypted MQTT message

**State Management Pattern:**

All state is held in composables using:
- `ref()` for reactive variables
- `useState()` for SSR hydration (data fetched on server is persisted to client)
- `computed()` for derived values
- `reactive()` for complex object state

Example (useOrganization):
```typescript
const organization = useState<Organization | null>('organization', () => null)
const role = useState<string | null>('org-role', () => null)

async function fetchOrganization() {
  const { data, error } = await supabase.functions.invoke('get-my-organization')
  organization.value = data.organization ?? null
  role.value = data.role ?? null
}
```

**Real-time Subscription Pattern:**

Composables open Postgres CDC channels and return a cleanup function:
```typescript
export function useMdbLog() {
  const logs = ref<Log[]>([])

  function subscribe(deviceId: string) {
    const channel = supabase
      .channel(`mdb-log-${deviceId}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'mdb_log', filter: `embedded_id=eq.${deviceId}` }, (payload) => {
        logs.value.unshift(payload.new)
      })
      .subscribe()

    return () => supabase.removeChannel(channel)
  }

  return { logs, subscribe }
}
```

Pages call `subscribe()` on `onMounted()` and cleanup with `onUnmounted()`.

## Key Abstractions

**VendingMachine Domain:**
- Purpose: Represents a physical vending machine with status, sales history, and inventory
- Location: `app/composables/useMachines.ts`, `app/pages/machines/`, `app/components/DashboardMachineList.vue`
- Pattern: Composable returns `machines` ref, `fetchMachines()`, `subscribeToStatusUpdates()`, calculated stock health/urgency
- Joins: `embeddeds` (device status), `sales` (revenue), `paxcounter` (foot traffic), `machine_trays` (stock)

**Embedded Device Domain:**
- Purpose: Represents an ESP32-S3 device with status, firmware version, MDB diagnostics
- Location: `app/composables/useMachines.ts`, `app/pages/machines/[id].vue`
- Pattern: Nested under `vendingMachine.embeddeds`, includes status enum (online/offline/initializing), firmware version, mdb_diagnostics JSONB
- Reflects: Real-time status via Postgres CDC on `embeddeds` table

**Product Catalog:**
- Purpose: Manage product definitions, categories, images, barcodes
- Location: `app/composables/useProducts.ts`, `app/pages/products/`
- Pattern: Composable wraps Supabase storage (product-images bucket) + RLS (company_id filtering)
- Image URL building: `getProductImageUrl(path)` constructs public URL from storage bucket

**Warehouse Inventory:**
- Purpose: Manage stock intake, FIFO batching, transaction history, min-stock alerts
- Location: `app/composables/useWarehouse.ts`, `app/pages/warehouse/`
- Pattern: Composable provides FIFO batch tracking, barcode lookup, deduction functions
- DB functions: `deduct_warehouse_stock_fifo()` handles refill stock deductions with expiry-first ordering

**Machine Trays (Stock Slots):**
- Purpose: Represent individual vending slots with product assignment and stock level
- Location: `app/composables/useMachineTrays.ts`, `app/pages/machines/[id].vue` (Trays tab)
- Pattern: Debounced stock updates (500ms wait) to prevent glitchy UI from rapid real-time updates + user edits
- DB trigger: `decrement_tray_stock` auto-decrements `current_stock` on sales

**Activity Log:**
- Purpose: Audit trail of user actions (stock adjustments, machine edits, product changes)
- Location: `app/composables/useActivityLog.ts`, `app/pages/history/`
- Pattern: Calls `history` table append function after each action

**MDB Diagnostics:**
- Purpose: Track ESP32 MDB state machine transitions and protocol errors
- Location: `app/composables/useMdbLog.ts`, `app/pages/machines/[id].vue` (MDB tab)
- Pattern: Cursor-based pagination (50 items per page), realtime subscription for new entries
- Exports: `stateLabel()` and `stateVariant()` helper functions for UI rendering

**Firmware Management:**
- Purpose: OTA firmware deployment to devices
- Location: `app/composables/useFirmware.ts`, `app/pages/firmware/`
- Pattern: Integrates with GitHub releases API + local Supabase storage bucket, calls `trigger-ota` edge function

## Entry Points

**Main App:**
- Location: `app/app.vue`
- Triggers: Browser load
- Responsibilities: Root layout template (`<NuxtLayout><NuxtPage />`)

**Homepage / Dashboard:**
- Location: `app/pages/index.vue`
- Triggers: Navigation to `/`
- Responsibilities: Load KPIs, fetch machine list, render sales chart, subscribe to realtime updates, handle pull-to-refresh

**Auth Pages:**
- Location: `app/pages/auth/login.vue`, `app/pages/auth/register.vue`
- Triggers: Direct navigation or redirect from protected routes
- Responsibilities: Form submission to Supabase auth, token storage, redirect to dashboard on success

**Onboarding Pages:**
- Location: `app/pages/onboarding/create-organization.vue`, `app/pages/onboarding/accept-invitation.vue`
- Triggers: Redirect from `auth` middleware if organization not found, or direct link via email
- Responsibilities: Organization creation via `create-organization` edge function, invitation acceptance via `accept-invitation` edge function

## Error Handling

**Strategy:** Try-catch in composables, user-facing error messages in page components.

**Patterns:**

1. **Composable-level errors:**
   ```typescript
   async function fetchMachines() {
     loading.value = true
     try {
       const { data, error } = await supabase.from('vendingMachine').select(...)
       if (error) throw error
       machines.value = data
     } catch (err) {
       console.error('Failed to fetch machines:', err)
       // Error is surfaced to caller
       throw err
     } finally {
       loading.value = false
     }
   }
   ```

2. **Page-level error handling:**
   ```typescript
   const errorMsg = ref('')
   onMounted(async () => {
     try {
       await loadData()
     } catch (err) {
       errorMsg.value = 'Failed to load machine. Please refresh.'
     }
   })
   ```

3. **Supabase auth errors:**
   - Automatically handled by `@nuxtjs/supabase` (token refresh, redirect to login on 401)
   - Manual error handling in edge function calls: check `error` object returned by `invoke()`

4. **Network errors:**
   - Composables catch and re-throw; pages decide whether to retry, show toast, or redirect
   - Pull-to-refresh automatically retries on network errors

## Cross-Cutting Concerns

**Logging:** Console-based (no central logging service)
- Pattern: `console.info()` for non-errors, `console.error()` for exceptions
- Service Worker: `console.info('[register-sw] ...')` for debug output

**Validation:**
- Client-side: Zod schema validation in form submission handlers
- Server-side: RLS policies in Supabase (all queries are filtered by `my_company_id()`)
- Pattern: Email validation on registration, barcode format validation on intake

**Authentication:**
- Strategy: Supabase JWT token stored in secure cookie (via `@nuxtjs/supabase`)
- Cookie name: `sb-vmflow-auth-token-{hash}` (fixed prefix, hostname-independent)
- Supabase user object available via `useSupabaseUser()` (auto-imported by Nuxt)
- Organization membership verified via `get-my-organization` edge function (returns organization + role)

**Authorization:**
- Strategy: Client-side role checks + Supabase RLS
- Pattern: Check `role.value === 'admin'` in components to show admin-only buttons/tabs
- RLS enforcement: All tables filtered by `my_company_id()` helper function (prevents cross-tenant data leaks)
- Edge functions: Manually verify JWT and organization membership via `adminClient.auth.getUser(token)`

**Internationalization:**
- Pattern: `const { t } = useI18n()` in components, then `t('nav.dashboard')`
- Locale files: `i18n/locales/en.json`, `i18n/locales/de.json`
- Fallback: English if browser language not supported
- Persistence: Locale choice stored in localStorage via `i18n_locale` cookie

**Styling:**
- Framework: Tailwind CSS 4 with custom config (spacing, colors, animations)
- Components: shadcn-nuxt + Reka UI primitives (Tabs, Sidebar, Card, etc.)
- Charts: Unovis Vue (`VisArea`, `VisLine`, `VisAxis`) for 30-day revenue/sales
- CSS imports: `app/assets/css/index.css` (Tailwind directives)
- Theme: Dark mode via `useTheme()` composable (uses `@vueuse/core` dark mode detection)

**State Persistence:**
- localStorage: Theme preference (`color-scheme`), i18n locale, PWA install dismiss flag
- Supabase session: JWT token in secure HTTP-only cookie (automatic)
- useState() caching: Composable state cached in Nuxt memory during SSR + hydrated on client

**Performance Optimizations:**
- Batch queries: `useMachines()` fetches today/yesterday/month sales in parallel via `Promise.all()`
- Debounced stock updates: `useMachineTrays()` waits 500ms before persisting stock changes (reduces DB load)
- Real-time subscriptions: Only open when needed (page mounted), cleanup on unmount
- Lazy component loading: Next.js-style dynamic imports via `defineAsyncComponent()` (where needed)
- Image optimization: Product images lazy-loaded, URL constructed client-side (no server re-renders)

---

*Architecture analysis: 2026-03-13*
