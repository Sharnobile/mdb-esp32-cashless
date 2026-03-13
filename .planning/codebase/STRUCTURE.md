# Codebase Structure

**Analysis Date:** 2026-03-13

## Directory Layout

```
mdb-esp32-cashless/
├── mdb-slave-esp32s3/          # ESP32-S3 MDB cashless device firmware (main product)
│   ├── main/                   # Firmware source code
│   │   ├── mdb-slave-esp32s3.c # Main FreeRTOS task loop: MDB protocol, MQTT, WiFi
│   │   ├── nimble.c            # BLE peripheral implementation
│   │   ├── webui_server.c      # HTTP captive portal for WiFi provisioning
│   │   └── CMakeLists.txt      # Build config with REQUIRES for ESP-IDF components
│   ├── webui/                  # HTML/JS for provisioning web UI
│   ├── build/                  # Compiled firmware (binary outputs)
│   └── sdkconfig               # ESP-IDF menuconfig settings
│
├── mdb-master-esp32s3/         # ESP32-S3 MDB master (VMC simulator for testing)
│   ├── main/                   # Firmware source code
│   │   ├── mdb-master-esp32s3.c # VMC state machine, polls MDB peripherals
│   │   └── webui_server.c      # HTTP server for master config
│   └── build/                  # Compiled firmware
│
├── Docker/                     # Backend services (Supabase, MQTT, frontend)
│   ├── docker-compose.yml      # Service orchestration (prod)
│   ├── .env.example            # Environment template
│   ├── setup.sh                # Initial setup script
│   ├── update.sh               # Update existing install
│   │
│   ├── supabase/               # Supabase configuration (local + prod)
│   │   ├── config.toml         # Supabase local dev config + edge function entries
│   │   ├── migrations/         # Database schema SQL files (numbered by date)
│   │   │   ├── 20260228000000_multitenancy.sql
│   │   │   ├── 20260228130000_device_provisioning.sql
│   │   │   └── ... (37 total)
│   │   ├── seed.sql            # Database seed data for local dev
│   │   ├── functions/          # Deno edge functions (18 total)
│   │   │   ├── claim-device/           # Firmware onboarding: provisioning code → device credentials
│   │   │   ├── send-credit/            # Admin: encrypt credit + publish to MQTT
│   │   │   ├── mqtt-webhook/           # Receives forwarded MQTT → validates → writes DB
│   │   │   ├── create-organization/    # User: create company + become admin
│   │   │   ├── get-my-organization/    # User: fetch org + role
│   │   │   ├── invite-member/          # Admin: invite user via email token
│   │   │   ├── accept-invitation/      # User: accept invite, join org
│   │   │   ├── trigger-ota/            # Admin: send firmware update URL to device
│   │   │   ├── create-provisioning-token/ # Admin: generate 8-char device code
│   │   │   ├── import-products/        # Admin: bulk import from Nayax Excel
│   │   │   ├── search-product-images/  # Product image AI search (OpenAI)
│   │   │   ├── register-push/          # User: register browser push subscription
│   │   │   ├── test-push/              # User: send test push notification
│   │   │   ├── send-device-config/     # Admin: send device config via MQTT
│   │   │   ├── create-api-key/         # Admin: generate API key for integrations
│   │   │   ├── request-credit/         # Firmware: request credit from backend
│   │   │   ├── import-github-release/  # Internal: auto-import firmware from GitHub releases
│   │   │   ├── main/                   # Internal: placeholder/testing
│   │   │   └── _shared/                # Shared utilities
│   │   │       ├── mqtt-publish.ts     # MQTT publish helper (WebSocket)
│   │   │       └── web-push.ts         # Web push sender
│   │   └── .env.example        # Supabase secrets template
│   │
│   ├── mqtt/                   # MQTT broker + forwarder
│   │   ├── docker-compose.yml  # Mosquitto + forwarder services (included in main compose)
│   │   ├── config/
│   │   │   ├── mosquitto.conf  # MQTT broker settings (ports 1883 TCP, 9001 WebSocket)
│   │   │   └── acl             # Access control list (vmflow user topics)
│   │   └── forwarder/
│   │       ├── main.ts         # Deno service: subscribe MQTT → forward to mqtt-webhook
│   │       ├── deno.json       # Deno dependencies (mqtt@5, encoding/base64)
│   │       └── Dockerfile      # Deno runtime image
│   │
│   ├── volumes/                # Persistent Docker data (db, api)
│   └── Dockerfile              # Frontend build (Nuxt → Node.js)
│
├── management-frontend/        # Web dashboard (Nuxt 4)
│   ├── nuxt.config.ts          # Nuxt entry point: modules, auth, PWA, i18n config
│   ├── package.json            # Dependencies: @nuxtjs/supabase, shadcn-nuxt, TailwindCSS 4, Unovis
│   ├── tsconfig.json           # TypeScript config
│   ├── vitest.config.ts        # Test runner config
│   │
│   ├── app/                    # Nuxt 4 app directory (auto-routed)
│   │   ├── app.vue             # Root component
│   │   │
│   │   ├── pages/              # Route pages (Nuxt auto-routes these)
│   │   │   ├── index.vue       # Dashboard: KPI cards, 30-day sales chart
│   │   │   ├── machines/
│   │   │   │   ├── index.vue   # Machines grid: responsive cards with stock urgency
│   │   │   │   └── [id].vue    # Machine detail: 30-day chart, sales history, trays + stock
│   │   │   ├── products/
│   │   │   │   └── index.vue   # Products: table, add/edit modal, image upload, categories, Nayax import
│   │   │   ├── warehouse/
│   │   │   │   └── index.vue   # Warehouse: stock intake (barcode scanner), FIFO batches, transactions, alerts
│   │   │   ├── devices/
│   │   │   │   └── index.vue   # Device management: registered devices, provisioning code + QR, pending tokens
│   │   │   ├── firmware/
│   │   │   │   └── index.vue   # Firmware: upload .bin, deploy OTA, delete versions
│   │   │   ├── members/
│   │   │   │   └── index.vue   # Team: active members, pending invites (admin only), invite modal
│   │   │   ├── api-keys/
│   │   │   │   └── index.vue   # API key management: create/revoke for external integrations
│   │   │   ├── history/
│   │   │   │   └── index.vue   # Activity/audit log
│   │   │   ├── settings/
│   │   │   │   └── index.vue   # Application settings
│   │   │   ├── auth/
│   │   │   │   ├── login.vue   # Login form (public)
│   │   │   │   └── register.vue # Registration form (public)
│   │   │   └── onboarding/
│   │   │       ├── create-organization.vue  # Create company (public, no auth)
│   │   │       └── accept-invitation.vue    # Accept invite via ?token= (public)
│   │   │
│   │   ├── middleware/
│   │   │   └── auth.ts         # Route guard: JWT + org fetch (skips SSR)
│   │   │
│   │   ├── composables/        # Vue composables (reusable logic)
│   │   │   ├── useOrganization.ts        # Fetch + cache org + role
│   │   │   ├── useMachines.ts            # Fetch machines, batch stats, realtime subscription
│   │   │   ├── useMachineTrays.ts        # CRUD trays, realtime stock updates
│   │   │   ├── useProducts.ts            # CRUD products, image upload/delete
│   │   │   ├── useWarehouse.ts           # Stock batches, transactions, barcode lookup, min-stock alerts
│   │   │   ├── useFirmware.ts            # Upload firmware, trigger OTA
│   │   │   ├── useImportProducts.ts      # Parse Nayax Excel, bulk import
│   │   │   ├── useNotifications.ts       # Browser push registration
│   │   │   ├── useMdbLog.ts              # Fetch + realtime MDB diagnostics
│   │   │   ├── useActivityLog.ts         # Audit trail
│   │   │   ├── usePullToRefresh.ts       # Pull-to-refresh gesture
│   │   │   ├── useTheme.ts               # Dark mode toggle (localStorage)
│   │   │   ├── useAppResume.ts           # App lifecycle events
│   │   │   ├── useAppUpdate.ts           # Service worker update detection
│   │   │   ├── useInstallPrompt.ts       # PWA install prompt
│   │   │   ├── useProductImageSearch.ts  # AI image search for products
│   │   │   └── __tests__/useMdbLog.test.ts # Vitest unit tests
│   │   │
│   │   ├── components/         # Vue components
│   │   │   ├── AppSidebar.vue          # Main navigation sidebar
│   │   │   ├── SiteHeader.vue          # Top header bar
│   │   │   ├── BarcodeScanner.vue      # Barcode scanner component (warehouse)
│   │   │   ├── BottomTabBar.vue        # Mobile bottom nav
│   │   │   ├── NavMain.vue, NavSecondary.vue, NavUser.vue  # Nav subcomponents
│   │   │   ├── LanguageSwitcher.vue    # i18n language selector
│   │   │   ├── ChartAreaInteractive.vue # Unovis interactive area chart
│   │   │   ├── DashboardActivityFeed.vue # Activity log display
│   │   │   ├── DashboardMachineList.vue # Dashboard machine cards
│   │   │   ├── DashboardRecentSales.vue # Recent sales list
│   │   │   ├── PullToRefresh.vue       # Pull-to-refresh behavior
│   │   │   ├── SectionCards.vue        # Reusable card grid
│   │   │   └── ui/                     # shadcn-nuxt UI components (auto-generated)
│   │   │       ├── button/
│   │   │       ├── card/
│   │   │       ├── dialog/
│   │   │       ├── input/
│   │   │       ├── tabs/
│   │   │       ├── sidebar/
│   │   │       └── ... (30+ components)
│   │   │
│   │   ├── layouts/
│   │   │   ├── default.vue     # Main layout: sidebar + content area
│   │   │   └── blank.vue       # Minimal layout (for auth pages)
│   │   │
│   │   ├── plugins/
│   │   │   ├── supabase-url.client.ts  # Rewrites Supabase URL from localhost → browser IP
│   │   │   └── register-sw.client.ts   # Service worker registration for PWA
│   │   │
│   │   ├── lib/
│   │   │   └── utils.ts        # Shared utilities: cn() (Tailwind merge), timeAgo(), formatCurrency()
│   │   │
│   │   ├── assets/             # Images, fonts
│   │   ├── service-worker/     # SW source (compiled to public/sw.js)
│   │   └── test-helpers/       # Nuxt stubs for vitest
│   │
│   ├── i18n/                   # Internationalization
│   │   ├── locales/
│   │   │   ├── en.json         # English strings
│   │   │   └── de.json         # German strings
│   │   └── i18n.config.ts      # i18n configuration
│   │
│   ├── public/                 # Static assets
│   │   ├── manifest.webmanifest # PWA manifest
│   │   ├── sw.js               # Service worker (compiled from service-worker/)
│   │   └── ... (icons, fonts)
│   │
│   ├── pages/                  # Old placeholder (Nuxt 3 convention, replaced by app/pages/)
│   ├── server/                 # Nuxt server routes (if any)
│   ├── .nuxt/, .output/        # Build artifacts (git-ignored)
│   └── node_modules/           # Dependencies (git-ignored)
│
├── docs/                       # Documentation
│   └── plans/                  # Phase plans + designs
│       ├── 2026-03-12-alerting-system.md
│       ├── 2026-03-12-mdb-level2-3-support-design.md
│       └── 2026-03-12-mdb-level2-3-support.md
│
├── .planning/                  # GSD codebase analysis documents
│   └── codebase/               # Analysis outputs
│       ├── ARCHITECTURE.md     # This file: pattern, layers, data flow
│       ├── STRUCTURE.md        # Directory layout and naming conventions
│       ├── CONVENTIONS.md      # Code style and patterns
│       └── TESTING.md          # Test framework and patterns
│
├── kicad/                      # Hardware schematics (KiCAD PCB designs)
│   ├── mdb-slave-esp32s3/
│   ├── mdb-slave-esp32s3-sim7080g/
│   ├── vmflow-mdb-esp32-sim7080g/
│   └── enclosure/
│
├── Android/                    # Mobile app (secondary)
├── 3d-printing/                # 3D models for enclosures
├── n8n-workflows-store/        # Automation workflows (n8n)
│
├── .env.example                # Root env template (for LAN setup)
├── CLAUDE.md                   # Project instructions for Claude
├── ARCHITECTURE.md             # High-level architecture overview (root)
├── DEV.md                      # Development setup guide
├── PROD.md                     # Production deployment guide
├── README.md                   # Project README
├── LICENSE                     # Open source license
└── .git/                       # Version control

```

## Directory Purposes

**mdb-slave-esp32s3:**
- Purpose: Main product firmware; runs on vending machine ESP32 device
- Contains: FreeRTOS tasks for MDB protocol, WiFi/MQTT networking, BLE pairing, provisioning
- Key files: `main/mdb-slave-esp32s3.c` (75KB, main event loop), `nimble.c` (BLE), `webui_server.c` (provisioning portal)

**mdb-master-esp32s3:**
- Purpose: Test/development VMC simulator; not shipped to production
- Contains: MDB master polling, button interrupt handler, LED control
- Key files: `main/mdb-master-esp32s3.c` (25KB, simulator logic)

**Docker/supabase:**
- Purpose: Database schema, migrations, edge functions, local dev environment
- Migrations numbered by date: schema evolution over time; always append (never modify)
- Functions: 18 Deno services for auth, MQTT, OTA, products, notifications

**Docker/mqtt:**
- Purpose: MQTT pub/sub infrastructure + webhook bridge
- Mosquitto: 1883 (TCP), 9001 (WebSocket for edge functions)
- Forwarder: subscribes to device topics, forwards to `mqtt-webhook` edge function

**management-frontend/app:**
- Purpose: Nuxt 4 app directory; auto-routed pages, composables, components
- Pages: 15 routes (dashboard, machines, products, warehouse, devices, firmware, team, settings, auth, onboarding)
- Composables: 13 reusable logic modules for data fetching + state
- Components: 40+ Vue components + 30 shadcn-nuxt UI primitives

## Key File Locations

**Entry Points:**

- **Firmware (mdb-slave):** `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` — FreeRTOS xTaskCreate() calls for mdb_cashless_loop, mqtt client, BLE, telemetry reader
- **Firmware (mdb-master):** `mdb-master-esp32s3/main/mdb-master-esp32s3.c` — polls MDB peripherals on ISR + scheduler
- **Backend:** `Docker/docker-compose.yml` — orchestrates all services (db, auth, functions, mqtt, broker, frontend)
- **Frontend:** `management-frontend/nuxt.config.ts` — Nuxt configuration; `management-frontend/app/app.vue` — root component

**Configuration:**

- **Frontend config:** `management-frontend/nuxt.config.ts` (Nuxt modules, PWA, i18n, Supabase settings)
- **Supabase local dev:** `Docker/supabase/config.toml` (ports, functions, secrets)
- **MQTT:**
  - `Docker/mqtt/config/mosquitto.conf` — broker settings
  - `Docker/mqtt/config/acl` — access control list (vmflow user topics)
- **Environment:**
  - `Docker/.env.example` — production/Docker env vars
  - `management-frontend/.env` — frontend-specific Supabase URL + key

**Core Logic:**

- **MDB Protocol:** `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` (state machine, UART handler, XOR validation)
- **MQTT Forwarder:** `Docker/mqtt/forwarder/main.ts` (subscribes `/+/+/{event}`, forwards to webhook)
- **Edge Functions:** `Docker/supabase/functions/` (18 Deno services)
  - `claim-device/index.ts` — device onboarding
  - `send-credit/index.ts` — encrypt + publish credit
  - `mqtt-webhook/index.ts` — validate + write received MQTT payloads
- **Frontend State:** `management-frontend/app/composables/` (13 composables managing data + realtime)

**Testing:**

- **Frontend unit tests:** `management-frontend/app/composables/__tests__/useMdbLog.test.ts`
- **Edge function tests:** `Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts`
- **Config:** `management-frontend/vitest.config.ts`, test helpers in `app/test-helpers/`

## Naming Conventions

**Files:**

- **Firmware C files:** snake_case, `.c` and `.h` (e.g. `mdb-slave-esp32s3.c`, `nimble.c`)
- **Nuxt pages/components:** PascalCase for components, snake_case for routes (e.g. `BarcodeScanner.vue`, `machines/[id].vue`)
- **Composables:** camelCase with `use` prefix (e.g. `useOrganization.ts`, `useMachineTrays.ts`)
- **Edge functions:** kebab-case directories with `index.ts` (e.g. `send-credit/index.ts`, `mqtt-webhook/index.ts`)
- **Migrations:** `{YYYYMMDDHHMM00}_{description}.sql` (e.g. `20260228000000_multitenancy.sql`)

**Directories:**

- **Firmware:** lowercase with hyphens (e.g. `mdb-slave-esp32s3`, `mdb-master-esp32s3`)
- **Backend services:** lowercase (e.g. `supabase`, `mqtt`, `functions`)
- **Frontend:** app/ convention (pages, composables, components, layouts, plugins)
- **Database:** migrations/ (numbered), functions/ (service names)

**Variables & Functions:**

- **Firmware (C):** snake_case for functions + variables (e.g. `mqtt_started`, `mdb_cashless_loop()`)
- **Frontend (TypeScript/Vue):** camelCase for functions/variables, PascalCase for components/interfaces (e.g. `const { organization } = useOrganization()`)
- **Database:** snake_case columns (e.g. `company_id`, `status_at`, `firmware_version`)
- **MQTT topics:** kebab-case for events, lowercase UUIDs (e.g. `/{company_id}/{device_id}/sale`)

## Where to Add New Code

**New Feature (Frontend):**
- **Page:** Create `management-frontend/app/pages/[feature]/index.vue` (routed automatically)
- **Logic:** Create `management-frontend/app/composables/use[Feature].ts` with state + fetch functions
- **Components:** Add reusable UI to `management-frontend/app/components/[Feature]*.vue`
- **Tests:** Add `management-frontend/app/composables/__tests__/use[Feature].test.ts`

**New Edge Function:**
- **Implementation:** Create `Docker/supabase/functions/[function-name]/index.ts`
- **Dependencies:** Create `Docker/supabase/functions/[function-name]/deno.json`
- **Config:** Add `[functions.[function-name]]` entry to `Docker/supabase/config.toml` with import_map
- **Entry in env:** If needs secrets, add to `Docker/.env.example`, `setup.sh`, `update.sh`, `config.toml` [edge_runtime.secrets], and docker-compose.yml build args

**New Firmware Component:**
- **Slave (mdb-slave):** Add `.c/.h` files in `mdb-slave-esp32s3/main/`, declare in `CMakeLists.txt` SRCS + new REQUIRES if using ESP-IDF component
- **Master (mdb-master):** Add `.c/.h` files in `mdb-master-esp32s3/main/`, update CMakeLists.txt

**New Database Table:**
- **Migration:** Create `Docker/supabase/migrations/{timestamp}_[table_name].sql`
- **RLS:** Add policies (SELECT, INSERT, UPDATE, DELETE) using `my_company_id()` helper for tenant isolation
- **Realtime:** Enable realtime with `ALTER TABLE [table] REPLICA IDENTITY FULL;`

**New MQTT Topic:**
- **ACL:** Add to `Docker/mqtt/config/acl` for vmflow user permissions
- **Forwarder:** Update topic filter in `Docker/mqtt/forwarder/main.ts` if webhook-bound
- **Edge function:** Add route to `mqtt-webhook/index.ts` or create new function if independent

**Shared Utilities:**
- **Frontend:** Add to `management-frontend/app/lib/utils.ts` (e.g. timeAgo, formatCurrency)
- **Edge functions:** Create in `Docker/supabase/functions/_shared/` (e.g. mqtt-publish.ts, web-push.ts)
- **Firmware:** Add to main file or new component (no separate utils folder convention)

## Special Directories

**Docker/supabase/migrations/**
- Purpose: Database schema evolution; each file is one transaction
- Generated: Manually created by developer
- Committed: Always; never modify existing files (breaks production)
- Pattern: Append-only (add new migration, never edit old ones)

**.planning/codebase/**
- Purpose: GSD analysis documents (ARCHITECTURE.md, STRUCTURE.md, CONVENTIONS.md, TESTING.md, CONCERNS.md)
- Generated: By `/gsd:map-codebase` command
- Committed: Yes
- Consumed by: `/gsd:plan-phase`, `/gsd:execute-phase` to understand codebase before implementing

**management-frontend/.nuxt/, .output/**
- Purpose: Build artifacts from Nuxt compiler
- Generated: `npm run build` or `npm run dev`
- Committed: No (.gitignore)

**mdb-slave-esp32s3/build/, cmake-build-debug/**
- Purpose: Compiled firmware binaries
- Generated: `idf.py build`
- Committed: No (.gitignore)

---

*Structure analysis: 2026-03-13*
