# Technology Stack

**Analysis Date:** 2026-03-13

## Languages

**Primary:**
- C (ESP-IDF 5.x) - Firmware for ESP32-S3 microcontroller (`mdb-slave-esp32s3/`, `mdb-master-esp32s3/`)
- TypeScript - Frontend and edge functions
- Kotlin - Android companion app (`Android/`)

**Secondary:**
- SQL/PL/pgSQL - Database and Supabase functions (`Docker/supabase/`)

## Runtime

**Environment:**
- ESP-IDF v5.x - Embedded firmware build system for ESP32-S3
- Deno v2.x - Edge function runtime (Supabase edge-runtime v1.67.4)
- Node.js v24-alpine - Frontend build and runtime (see `management-frontend/Dockerfile`)

**Package Manager:**
- npm - Frontend package management (`management-frontend/package.json`)
- Deno - Edge function imports via `deno.json` and JSR/npm registry imports (e.g., `npm:mqtt@5`)
- CMake - Firmware build system (ESP-IDF)
- Gradle - Android build (`Android/gradle/libs.versions.toml`)

**Lockfile:**
- `management-frontend/package-lock.json` - npm lockfile present

## Frameworks

**Core:**
- Nuxt 4.2.2 - Full-stack Vue framework with SSR (`management-frontend/`)
- ESP-IDF 5.x - FreeRTOS real-time OS for firmware
- Supabase (local + Docker) - Backend-as-a-service: PostgreSQL, Auth (GoTrue), Realtime, Storage, Edge Functions

**Frontend UI:**
- Vue 3.5.26 - Progressive framework
- shadcn-nuxt 2.4.3 - Headless component library
- TailwindCSS 4.1.18 - Utility-first CSS
- Reka UI 2.7.0 - React component library (Vue port)
- @tabler/icons-vue 3.36.1 - Icon library
- Lucide Vue Next 0.562.0 - SVG icon library

**Frontend Charts & Data Visualization:**
- @unovis/vue 1.6.2 - Data visualization library
- @tanstack/vue-table 8.21.3 - Headless table component

**Frontend Features:**
- @vueuse/core 14.1.0 - Vue composition utilities
- Barcode detector 3.1.1 - Web API for barcode scanning (`app/components/BarcodeScanner.vue`)
- qrcode 1.5.4 - QR code generation
- dnd-kit-vue 0.0.2 - Drag-and-drop library

**Data & i18n:**
- @nuxtjs/i18n 10.2.3 - Internationalization (EN, DE)
- xlsx 0.18.5 - Excel file parsing (Nayax product imports)
- zod 4.3.5 - TypeScript schema validation
- clsx 2.1.1 - Conditional className utility
- tailwind-merge 3.4.0 - TailwindCSS class merging

**Testing:**
- Vitest 4.0.18 - Unit test framework (`management-frontend/vitest.config.ts`)
- @vue/test-utils 2.4.6 - Vue component testing utilities
- happy-dom 20.8.3 - DOM implementation for testing

**Build & Development:**
- @nuxtjs/tailwindcss 7.0.0-beta.1 - Tailwind integration for Nuxt
- @vite-pwa/nuxt 1.1.1 - PWA support
- tw-animate-css 1.4.0 - Animation utilities
- @nuxtjs/supabase 2.0.3 - Supabase integration plugin

**Firmware Components:**
- NimBLE (BLE) - Bluetooth LE protocol stack (in `mdb-slave-esp32s3/main/nimble.c`)
- MQTT (esp-mqtt) - MQTT client library
- cJSON - JSON parsing library
- esp_http_client - HTTP client for OTA updates
- mbedtls - TLS/SSL crypto

## Key Dependencies

**Critical:**
- @nuxtjs/supabase 2.0.3 - Supabase client integration
- mqtt 5.x (npm package in forwarder) - MQTT client for message broker communication
- @supabase/supabase-js 2.x (in edge functions via esm.sh) - Supabase client SDK
- jose v4.14.4 (Deno module) - JWT verification for edge functions

**Infrastructure:**
- PostgreSQL 15.8.1.060 - Relational database (via `supabase/postgres:15.8.1.060`)
- Eclipse Mosquitto 2.1.2-alpine - MQTT message broker
- Kong 2.8.1 - API gateway
- Supabase modules (multiple containers):
  - GoTrue v2.177.0 - Authentication
  - PostgREST v12.2.12 - REST API
  - Realtime v2.34.47 - WebSocket subscriptions
  - Storage API v1.25.7 - File storage
  - Postgres Meta v0.91.0 - Database introspection
  - Supabase Studio 2025.06.30 - Web UI
  - imgproxy v3.8.0 - Image transformation

**Android Dependencies:**
- Kotlin 2.0.21 - Language
- Compose - UI toolkit (androidx-compose-bom 2024.09.00)
- Material 3 - Design system
- Activity & Lifecycle - Android architecture components

## Configuration

**Environment:**
- `.env` file (Docker) - Service configuration and secrets
- `Docker/supabase/config.toml` - Supabase local dev config (API port 54321, DB port 54322, Studio 54323)
- `nuxt.config.ts` - Frontend build configuration with runtimeConfig (VAPID keys, GitHub firmware repo, build metadata)
- `vitest.config.ts` - Test runner configuration
- CMakeLists.txt - Firmware build configuration with REQUIRES declarations for components

**Secrets Management:**
- `.env` and `.env.example` - Docker environment variables
- `Docker/supabase/.env` - Local Supabase development secrets
- No committed credentials; production secrets via `Docker/setup.sh` generation

**Build:**
- `Docker/docker-compose.yml` - Multi-service orchestration (17 services)
- `management-frontend/Dockerfile` - Multi-stage Node build (builder → runtime)
- `Docker/mqtt/forwarder/Dockerfile` - Deno runtime for MQTT→Webhook bridge
- ESP-IDF CMake-based build with `idf.py` commands

## Platform Requirements

**Development:**
- ESP-IDF v5.x environment (`. $IDF_PATH/export.sh`)
- Node.js v24 for frontend
- Deno v2 for edge function development
- Docker + Docker Compose for backend services
- CMake 3.16+ for ESP-IDF

**Production:**
- Docker with docker-compose for self-hosted backend
- ESP32-S3 microcontroller with WiFi capability
- MQTT broker (Mosquitto or compatible)
- PostgreSQL 15.8+ database
- Deno edge-runtime v1.67.4 for serverless functions
- Node.js v24-alpine for Nuxt runtime

**Firmware Deployment:**
- OTA (Over-the-Air) updates via edge function `trigger-ota` → MQTT → firmware
- Provisioning flow: SoftAP captive portal → claim-device endpoint → device firmware activation

---

*Stack analysis: 2026-03-13*
