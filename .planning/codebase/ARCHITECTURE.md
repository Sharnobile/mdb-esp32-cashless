# Architecture

**Analysis Date:** 2026-03-13

## Pattern Overview

**Overall:** Multi-layer distributed system with firmware, serverless edge functions, MQTT messaging, and web frontend.

**Key Characteristics:**
- **Decoupled communication**: MQTT broker connects ESP32 devices to backend; devices don't call API directly
- **Stateless edge functions**: Supabase Deno edge functions process requests (no persistent connections)
- **Real-time subscriptions**: Frontend uses Supabase realtime for live data updates
- **Multi-tenant**: All data scoped by `company_id`; RLS enforces isolation via `my_company_id()` and `i_am_admin()` helpers
- **XOR encryption**: All sensitive MQTT payloads use XOR cipher with passkey + timestamp validation

## Layers

**Firmware (mdb-slave-esp32s3):**
- Purpose: MDB protocol handler and MQTT client on ESP32-S3; manages vending machine state transitions
- Location: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`, `nimble.c`, `webui_server.c`
- Contains: MDB state machine (INACTIVE → DISABLED → ENABLED → IDLE → VEND), MQTT publishing, BLE peripheral, WiFi provisioning, OTA updates, DEX/DDCMP reader
- Depends on: ESP-IDF v5.x, FreeRTOS, NimBLE, MQTT client library, cJSON
- Used by: MDB master (VMC simulator) on UART2, WiFi/MQTT network

**Firmware (mdb-master-esp32s3):**
- Purpose: Simulates a vending machine controller (VMC) for testing; polls MDB peripherals
- Location: `mdb-master-esp32s3/main/mdb-master-esp32s3.c`, `webui_server.c`
- Contains: MDB master state machine, button ISR for vend triggers, LED strip control, DEX reader
- Depends on: ESP-IDF v5.x, FreeRTOS
- Used by: Testing and development

**Backend Services (Docker):**
- **Supabase (db, auth, functions, realtime):** PostgreSQL multi-tenant database, JWT auth, Deno edge runtime, realtime subscriptions
  - Location: `Docker/supabase/`
  - Functions: `Docker/supabase/functions/`
  - Migrations: `Docker/supabase/migrations/`
- **MQTT Broker (Mosquitto):** Message hub for device pub/sub
  - Location: `Docker/mqtt/config/`
  - Configuration: ACL rules in `acl` file; WebSocket listener on port 9001 (for edge functions)
- **MQTT Forwarder (Deno):** Bridges MQTT topics to Supabase webhook
  - Location: `Docker/mqtt/forwarder/main.ts`
  - Subscribes: `/+/+/sale`, `/+/+/status`, `/+/+/paxcounter`, `/+/+/mdb-log`
  - Forwards: Base64-encoded payloads to `mqtt-webhook` edge function

**Frontend (management-frontend):**
- Purpose: Web dashboard for managing machines, products, warehouse, devices, team
- Location: `management-frontend/app/`
- Stack: Nuxt 4, TypeScript, Vue 3, TailwindCSS 4, shadcn-nuxt, Unovis charts
- Uses: Supabase client for auth + queries + realtime subscriptions
- Deployed: Docker container (Nuxt build + Node.js server)

## Data Flow

**Provisioning Flow (Firmware Onboarding):**

1. ESP32 boots; no saved WiFi credentials → starts SoftAP + captive portal HTTP server
2. Mobile user connects to SoftAP, visits `http://192.168.4.1`, enters WiFi SSID/password + provisioning code + backend URL
3. WebUI POST to `webui_server.c` endpoint → saves to NVS, calls `esp_wifi_connect()`
4. On `IP_EVENT_STA_GOT_IP`: firmware spawns `provision_claim_task`
5. `provision_claim_task` POSTs `{short_code, mac_address}` to backend `claim-device` edge function
6. `claim-device` validates code in `device_provisioning` table, creates `embeddeds` row, returns `{company_id, device_id, passkey, mqtt_host, mqtt_port}`
7. Firmware saves to NVS (`vmflow` namespace), erases `prov_code`, calls `esp_restart()`
8. After reboot: device connects to MQTT broker, publishes status on `/{company}/{device}/status`

**Sale Event Flow:**

1. Vending machine (MDB master) detects coin/card → sends VEND request to MDB cashless device (mdb-slave-esp32s3)
2. ESP32 transitions to VEND_STATE, publishes credit request to backend (encrypted) on `/{company}/{device}/credit`
3. Frontend user approves via dashboard → calls `send-credit` edge function
4. `send-credit` encrypts credit with passkey + timestamp, publishes to `/{company}/{device}/credit` MQTT topic
5. ESP32 receives credit on MQTT, decrypts, validates timestamp (±8s replay window), responds to MDB master with VEND_SUCCESS
6. MDB master completes vend, ESP32 publishes sale event to `/{company}/{device}/sale` (XOR-encrypted)
7. MQTT forwarder forwards encrypted payload to `mqtt-webhook` edge function (with `X-Webhook-Secret` auth)
8. `mqtt-webhook` decrypts, validates checksum + timestamp, writes to `sales` table with `item_price`, `item_number`, `channel`
9. Frontend realtime subscription on `sales` table updates dashboard in real-time
10. Stock auto-decrements via `decrement_tray_stock` database trigger on `machine_trays`

**Status/Diagnostics Flow:**

1. ESP32 publishes status periodically (5min heartbeat or on state change) to `/{company}/{device}/status`
   - Format: plaintext, no encryption (e.g. `online|v:1.0.0|b:Mar  1 2026 14:30:00 +0100`)
2. MQTT forwarder forwards to `mqtt-webhook`
3. `mqtt-webhook` parses status, firmware version, build date; updates `embeddeds.status`, `embeddeds.firmware_version`, `embeddeds.firmware_build_date`
4. On state changes, ESP32 publishes diagnostics to `/{company}/{device}/mdb-log` (plaintext JSON)
   - Contains: `state`, `addr`, `polls`, `chkErr`, `lastCmd`, plus counters
5. `mqtt-webhook` inserts into `mdb_log` table; frontend realtime subscription shows live diagnostics

**OTA Update Flow:**

1. Admin user uploads firmware .bin to `firmware` storage bucket via dashboard
2. `useFirmware` composable calls `trigger-ota` edge function with device ID + firmware URL
3. `trigger-ota` encrypts URL with passkey + timestamp, publishes to `/{company}/{device}/ota` MQTT topic
4. ESP32 receives encrypted OTA URL, validates, calls `esp_https_ota_begin()` with `esp_crt_bundle_attach()`
5. Firmware downloads and flashes; on success, publishes status update

**State Management:**

- **Frontend state**: Composables use `useState()` (Nuxt SSR-safe state containers) cached at top level
  - `useOrganization()`: organization name, user role, cached in `useState('organization')`
  - `useMachines()`: machines list with real-time realtime subscription on `embeddeds` + `vendingMachine` + `sales` tables
  - `useProducts()`: products catalog, images, categories
  - `useMachineTrays()`: per-machine tray configuration with realtime stock updates
  - `useWarehouse()`: stock batches (FIFO), transactions, min-stock alerts

- **Firmware state**: Machine state machine stored in RAM (`machine_state_t`), persists device config to NVS
  - NVS namespace `vmflow`: `company_id`, `device_id`, `passkey`, `mqtt_host`, `mqtt_port`, `mdb_address`

- **Database state**: Supabase PostgreSQL with RLS; all queries filtered by `company_id` via `my_company_id()` function

## Key Abstractions

**XOR Encryption (Payload Format):**
- Purpose: Encrypt sensitive MQTT messages without hardware crypto
- Format: 19 bytes `[cmd(1) | version(1) | param(4) | itemNumber(2) | timestamp(4) | padding(6) | checksum(1)]`
- Cipher: XOR each byte [1..18] with passkey bytes (cycling); timestamp ±8s replay window
- Used in: `credit`, `config`, `sale` MQTT events and BLE payloads
- Code: `xorDecodeWithPasskey()` in firmware; `send-credit` edge function implements encryption
- Config commands: `0x20`=credit, `0x30`=restart, `0x31`=mdb_address

**MDB Protocol:**
- Purpose: Talk to vending machine controller (master) or simulate one
- Location: Implemented in `mdb-slave-esp32s3.c` (slave) and `mdb-master-esp32s3.c` (master)
- State machine: `INACTIVE → DISABLED → ENABLED → IDLE → VEND → IDLE`
- Commands: RESET, SETUP, POLL, VEND, READER, EXPANSION
- UART: GPIO4 RX, GPIO5 TX, 9600 baud, 9-bit mode (special bit for address matching)

**Multi-Tenancy via RLS:**
- Purpose: Isolate companies' data at database level
- Helper functions in migrations:
  - `my_company_id()` — reads from `organization_members(current_user_id)` JWT
  - `i_am_admin()` — checks role in `organization_members`
- Applied to: All tables via RLS policies (ON SELECT, INSERT, UPDATE, DELETE)
- Frontend: Fetches `organization` via `get-my-organization` edge function (calls `my_company_id()` server-side)

**Realtime Subscriptions:**
- Purpose: Live-update dashboard when data changes
- Channels: `useMachines()` subscribes to `embeddeds`, `vendingMachine`, `sales` tables with `on('*')` trigger
- Frontend: Dashboard KPI cards, machine cards, sales history update instantly when new data arrives

## Entry Points

**Firmware (mdb-slave):**
- Location: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c`
- Triggers: System boot
- Responsibilities: FreeRTOS task setup, WiFi/MQTT init, MDB UART handler loop, BLE peripheral, OTA, telemetry reader

**Firmware (mdb-master):**
- Location: `mdb-master-esp32s3/main/mdb-master-esp32s3.c`
- Triggers: System boot
- Responsibilities: Poll MDB peripherals, button ISR for vend trigger, LED strip control

**Frontend:**
- Location: `management-frontend/app/app.vue` (root component)
- Rendered by: Nuxt 4 SSR + client hydration
- Middleware: `app/middleware/auth.ts` checks JWT before rendering protected routes
- Entry point for data: `app/pages/` routes (Nuxt auto-routed)

**Backend:**
- Entry points: Docker Compose services
  - `kong` (API gateway) → routes to Supabase functions
  - `db` (PostgreSQL) → schemas, RLS policies, migrations
  - `functions` (Deno edge runtime) → 18 edge functions in `Docker/supabase/functions/`
  - `broker` (Mosquitto) → MQTT pub/sub
  - `forwarder` (Deno) → bridges MQTT to HTTP webhook

## Error Handling

**Strategy:** Defensive validation at each layer; graceful fallback in UI

**Patterns:**

- **Firmware**: Logging via `ESP_LOG*` macros; state machine validates inputs before transition; on error: log "MDB DIAG: ..." or "MDB STATE: ..." + retry or reboot
- **Edge functions**: Check auth headers first; validate request shape; return HTTP error + JSON error message; let Deno runtime handle unhandled exceptions (500)
- **Frontend composables**: Try/catch around Supabase calls; set `loading`, `error` state; display toast or error UI; allow user retry
- **MQTT**: Forwarder reconnects on disconnect; broker queues QoS 1 messages; firmware validates passkey before processing

## Cross-Cutting Concerns

**Logging:**
- Firmware: `ESP_LOGD()`, `ESP_LOGI()`, `ESP_LOGW()`, `ESP_LOGE()` via UART0
- Edge functions: `console.log()` (logged by Deno runtime)
- Frontend: `console.log()` (browser console) + error tracking (if configured)

**Validation:**
- Firmware: MDB checksum validation, XOR passkey validation with timestamp
- Edge functions: JWT/API key verification, request shape validation (zod schemas recommended but not enforced)
- Frontend: Zod schema validation (e.g. in `useImportProducts` for Excel parsing); form field validation in UI

**Authentication:**
- Firmware: XOR passkey (symmetric, device-specific) + timestamp window
- Frontend + edge functions: Supabase JWT (asymmetric, user-bound) + service role key (admin operations)
- API keys: SHA-256 hash stored in DB; `send-credit` accepts either JWT or API key header

**Authorization:**
- Firmware: Device can only publish to its own topic `/{company_id}/{device_id}/*`
- Frontend: Protected routes require JWT; MQTT topics require admin role for `send-credit`
- Database: RLS policies enforce `company_id` isolation; functions use `i_am_admin()` for sensitive operations

---

*Architecture analysis: 2026-03-13*
