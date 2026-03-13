# Technology Stack

**Analysis Date:** 2026-03-13

## Languages

**Primary:**
- **TypeScript** 5.9.3 - Frontend codebase in `management-frontend/`; strict mode enforced by Nuxt 4
- **JavaScript** (ES2024) - Build scripts, configuration files, Nuxt runtime
- **Deno/TypeScript** - Edge functions (Deno v1.x runtime)
- **SQL** (PostgreSQL 15.8.1) - Database migrations and stored procedures in `Docker/supabase/`

**Secondary:**
- **C** - Firmware (mdb-slave-esp32s3, mdb-master-esp32s3) using ESP-IDF v5.x
- **YAML** - Docker Compose configuration (`Docker/docker-compose.yml`)

## Runtime

**Environment:**
- **Node.js 24 Alpine** - Frontend server and build toolchain; see `management-frontend/Dockerfile`
- **Deno** - Edge function runtime (via `supabase/edge-runtime:v1.67.4` container)
- **PostgreSQL 15.8.1** - Database (`supabase/postgres:15.8.1.060`)
- **ESP-IDF v5.x** - Firmware build environment (C, FreeRTOS, CMake)

**Package Manager:**
- **npm** 10+ - Frontend dependencies; `package.json` and `package-lock.json` in `management-frontend/`
- Lockfile: Present (`package-lock.json`; 25+ MB, reflects all transitive dependencies)

## Frameworks

**Core:**
- **Nuxt 4.2.2** - Full-stack metaframework (SSR, hybrid rendering, auto-routing)
  - Location: `management-frontend/`
  - App directory: `management-frontend/app/` (Nuxt 4 convention)
  - Pages: `app/pages/`, Composables: `app/composables/`, Components: `app/components/`
- **Vue 3.5.26** - Progressive JavaScript framework; reactive, component-based UI
- **Vue Router 4.6.4** - Client-side routing

**UI & Styling:**
- **shadcn-nuxt 2.4.3** - Unstyled, accessible component library built on Radix Vue
  - Re-exported as `reka-ui 2.7.0` (Radix Vue wrapper)
  - Components: `app/components/ui/` (auto-imported)
- **TailwindCSS 4.1.18** - Utility-first CSS framework
  - Config: Inherited from `@nuxtjs/tailwindcss` module (no separate `tailwind.config.ts` found)
  - Bundled with `tw-animate-css 1.4.0` for animation utilities
- **Tailwind Merge 3.4.0** - Resolves conflicting Tailwind classes; used in `app/lib/utils.ts`
- **clsx 2.1.1** - Conditional className utility; used in `cn()` helper

**Data Visualization:**
- **Unovis 1.6.2** - TypeScript-first, framework-agnostic visualization library
  - `@unovis/ts 1.6.2` (core)
  - `@unovis/vue 1.6.2` (Vue integration)
  - Used for 30-day sales/revenue charts on dashboard and machine detail pages

**Database & Auth:**
- **@nuxtjs/supabase 2.0.3** - Nuxt integration for Supabase client
  - Abstracts Supabase JS client initialization
  - Provides composable: `useSupabaseClient()`, `useSupabaseUser()`
  - Auth: Email/password (GoTrue v2.177.0)
  - Realtime subscriptions: Supabase Realtime v2.34.47 (PostgreSQL changes via WebSocket)
  - REST API: PostgREST v12.2.12 (auto-generated from schema)
  - Storage: Supabase Storage v1.25.7 (file uploads for product images, firmware)

**Tables & Data Access:**
- **TanStack Vue Table 8.21.3** - Headless table component library
  - Used in admin pages (e.g., `/devices`, `/members`, `/api-keys`, sales history)
  - Supports sorting, pagination, filtering, and column visibility

**Utilities:**
- **@vueuse/core 14.1.0** - Vue composition utilities
  - `useDark()` for theme toggle (stored in `localStorage` as `color-scheme`)
  - Other composables: `useAsync()`, `useEventListener()`, etc.
- **qrcode 1.5.4** - QR code generation (device provisioning flow)
- **xlsx 0.18.5** - Excel parsing and generation
  - Used for Nayax product import (`/import-products` edge function consumes Excel exports)
  - Used for exporting sales history and inventory data
- **zod 4.3.5** - TypeScript-first schema validation
  - Validates form inputs, API payloads, edge function responses
  - Custom validators in `app/lib/validators/` (if present)

**i18n:**
- **@nuxtjs/i18n 10.2.3** - Internationalization module for Nuxt
  - Locales: English (`en.json`), Deutsch (`de.json`)
  - Default: English
  - Browser language detection + cookie persistence
  - Lazy-loaded locale files from `i18n/locales/`

**Testing:**
- **Vitest 4.0.18** - Unit and integration test framework (Jest-compatible)
  - Config: `management-frontend/vitest.config.ts`
  - Environment: `happy-dom` (lightweight DOM implementation)
  - Test files: `app/**/*.test.ts` and `app/**/*.spec.ts`
- **@vue/test-utils 2.4.6** - Vue component testing utilities
- **happy-dom 20.8.3** - Lightweight DOM implementation for test isolation

**Dev Tools & Build:**
- **Vite** - Modern module bundler (via Nuxt, under the hood)
- **@vite-pwa/nuxt 1.1.1** - PWA support (Web App Manifest, service worker)
  - Manifest: `app/app.vue` meta tags + `public/manifest.webmanifest`
  - Service worker: Disabled precaching in Nuxt config (custom `public/sw.js` avoids Workbox iOS bugs)
- **vue-tsc 3.2.2** - Type-checking (not needed; Nuxt handles it via Vite)
- **TypeScript 5.9.3** - Type safety and IDE support

**Drag & Drop:**
- **dnd-kit-vue 0.0.2** - Vue 3 bindings for dnd-kit
  - Used for reorderable lists (e.g., tray slot assignments)

**Icons:**
- **@tabler/icons-vue 3.36.1** - Tabler icon set (180+ icons)
- **lucide-vue-next 0.562.0** - Lucide icon set (1000+ icons)
  - Both integrated with shadcn-nuxt components

**Class Variants:**
- **class-variance-authority 0.7.1** - CSS-in-JS utility for component variants
  - Used by shadcn-nuxt for component styling flexibility

## Configuration

**Environment:**
- **Frontend (.env in `management-frontend/`):**
  - `SUPABASE_URL` - API gateway URL (e.g., `http://127.0.0.1:54321` locally, `https://api.vmflow.xyz` in prod)
  - `SUPABASE_KEY` - Supabase anon key (public, safe for client)
  - Runtime override: `NUXT_PUBLIC_SUPABASE_URL` and `NUXT_PUBLIC_SUPABASE_KEY` via Docker environment
  - Other public config: `VAPID_PUBLIC_KEY`, `GITHUB_FIRMWARE_REPO` (see `nuxt.config.ts` `runtimeConfig`)

- **Docker Backend (.env in `Docker/`):**
  - Database: `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`
  - Auth: `JWT_SECRET` (32+ chars), `ANON_KEY`, `SERVICE_ROLE_KEY` (generated JWT tokens)
  - MQTT: `MQTT_WEBHOOK_SECRET` (shared between forwarder and `mqtt-webhook` edge function)
  - Web Push: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`
  - Firebase: `FCM_SERVICE_ACCOUNT_JSON` (optional, for native push)
  - GitHub: `GITHUB_FIRMWARE_REPO` (e.g., `owner/repo` for firmware releases)
  - Secrets auto-generated: `setup.sh` and `update.sh` scripts

- **Supabase Local Dev (.env in `Docker/supabase/`):**
  - Not checked in (generated via `supabase start`)
  - `OPENAI_API_KEY` - For Supabase AI (Studio only)
  - Database vars: `POSTGRES_PASSWORD`, `JWT_SECRET`, JWT keys

- **Nuxt Build Args:**
  - `GIT_HASH` - Passed at Docker build time (for version display)
  - `BUILD_DATE` - Passed at Docker build time (for build info)
  - Baked into `runtimeConfig.public` during build

**Build:**
- **Nuxt Config:** `management-frontend/nuxt.config.ts`
  - `compatibilityDate: '2025-07-15'` - Nuxt version stability marker
  - SSR enabled (hybrid rendering: SSR + pre-render where possible)
  - Route rules: `/functions/**` proxied to Supabase API (for LAN device access)
  - Module: `@nuxtjs/tailwindcss` (no separate Tailwind config file)
  - PWA: Disabled precaching (custom service worker only)
- **TypeScript:** Managed by Nuxt auto-generated files (`.nuxt/tsconfig.*.json`)
- **Vite:** Configured implicitly by Nuxt, with custom route rules for Supabase proxy

## Key Dependencies

**Critical:**
- **@nuxtjs/supabase** - All backend communication; no custom HTTP client
  - Used in 13+ composables (`useOrganization`, `useMachines`, `useProducts`, `useWarehouse`, etc.)
  - Realtime subscriptions for live updates on sales, trays, device status
  - File uploads to `product-images` and `firmware` storage buckets
- **shadcn-nuxt + @nuxtjs/tailwindcss** - All UI; no custom component library

**Infrastructure:**
- **Supabase Stack:**
  - PostgreSQL 15.8.1 (relational data, RLS policies)
  - PostgREST (auto-generated REST API)
  - GoTrue (authentication)
  - Realtime (WebSocket subscriptions)
  - Storage API (file storage)
  - Edge Runtime (Deno-based edge functions)
  - Kong (API gateway)
- **MQTT:**
  - Eclipse Mosquitto 2.1.2-alpine (broker)
  - Deno forwarder (`Docker/mqtt/forwarder/main.ts`) bridges MQTT to Supabase webhooks
  - Web push notifications via VAPID (Web Push Protocol)
  - Firebase Cloud Messaging (optional, for native mobile push)

**Optional:**
- **OpenAI API** - For Supabase AI in Studio (Studio only, not in production app)
- **GitHub** - For firmware release imports (opt-in via `GITHUB_FIRMWARE_REPO` env var)

## Platform Requirements

**Development:**
- Node.js 20+ (npm 10+)
- Docker + Docker Compose (for Supabase, MQTT, Postgres)
- Supabase CLI (for local `supabase start`)
- TypeScript 5.9+
- Modern browser with WebSocket support (for Realtime)

**Production:**
- Docker 20.10+
- Docker Compose (single `docker-compose.yml` deploys all services)
- 2+ GB RAM (for Postgres, Mosquitto, Supabase services)
- HTTPS (TLS certificates for Kong reverse proxy)
- VAPID keys for web push (auto-generated by `setup.sh`)

---

*Stack analysis: 2026-03-13*
