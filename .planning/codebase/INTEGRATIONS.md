# External Integrations

**Analysis Date:** 2026-03-13

## APIs & External Services

**MQTT Message Broker:**
- Eclipse Mosquitto 2.1.2 - Bidirectional device-to-backend messaging
  - Client: esp-mqtt library in firmware; mqtt npm package in forwarder
  - Topic format: `/{company_id}/{device_id}/{event}`
  - Pub events: `sale`, `status`, `paxcounter`, `dex`, `mdb-log`
  - Sub events: `credit`, `ota`, `config`
  - Port: 1883 (internal), configurable public port
  - Auth: vmflow/vmflow (devices), admin user (forwarder + edge functions)
  - Webhook bridge: `Docker/mqtt/forwarder/main.ts` forwards payloads to `mqtt-webhook` edge function

**GitHub Releases (Firmware OTA):**
- API: GitHub release downloads for firmware binaries
  - Integration: `import-github-release` edge function fetches latest releases
  - Config: `GITHUB_FIRMWARE_REPO` env var (owner/repo format)
  - Used by: Firmware management UI (`/firmware` page)

**Web Push Notifications (VAPID):**
- Browser Push API - Native push notifications
  - Keys: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`
  - Functions: `register-push`, `test-push` edge functions
  - Storage: Browser push subscriptions stored in `push_subscriptions` DB table
  - Used by: User-facing alerts (stock, sales, device status)

**Firebase Cloud Messaging (FCM):**
- Native iOS/Android push notifications (optional)
  - Config: `FCM_SERVICE_ACCOUNT_JSON` env var (full service account JSON)
  - Integration: Edge function push handlers check for FCM credentials
  - Status: Disabled if `FCM_SERVICE_ACCOUNT_JSON` is empty

**OpenAI API (Optional):**
- Supabase Studio SQL Editor Assistant
  - Config: `OPENAI_API_KEY` env var
  - Used: Studio UI only (not backend)
  - Status: Optional integration

## Data Storage

**Databases:**
- PostgreSQL 15.8.1.060 (supabase/postgres container)
  - Connection: `postgres://{user}:{password}@{POSTGRES_HOST}:{POSTGRES_PORT}/{POSTGRES_DB}`
  - Client: Supabase client (PostgREST API) via `@supabase/supabase-js`
  - Replication: Logical replication enabled for Realtime
  - Auth: `supabase_admin`, `authenticator`, `supabase_auth_admin`, `supabase_storage_admin` roles

**File Storage:**
- Supabase Storage - Self-hosted local filesystem storage
  - Buckets (from `Docker/supabase/config.toml`):
    - `product-images`: public, 2MiB limit, PNG/JPEG/WebP (product catalog images)
    - `firmware`: public, 5MiB limit, binary files (OTA firmware updates)
  - Backend: Local filesystem at `Docker/volumes/storage/`
  - Image transformation: imgproxy v3.8.0 container for thumbnail/resize operations
  - API: Supabase Storage REST API via PostgREST

**Caching:**
- None centralized (Redis not deployed)
- Frontend browser caching: Realtime subscriptions via WebSocket
- Supabase client-side caching: Query results cached in useState composables

## Authentication & Identity

**Auth Provider:**
- Supabase GoTrue (v2.177.0) - Self-hosted authentication
  - JWT issuer: `{API_EXTERNAL_URL}/auth/v1`
  - Token expiry: Configurable via `JWT_EXPIRY` (default 3600s)
  - Methods: Email/password signup + login, optional SMS/TOTP (disabled in default config)
  - External OAuth: Support for Apple, Google, GitHub, etc. (disabled by default)

**Multi-tenancy:**
- Row-level security (RLS) via Supabase policies
  - Helper functions: `my_company_id()`, `i_am_admin()` in `Docker/supabase/`
  - Org table: `organization_members(company_id, user_id, role)` where role ∈ {admin, viewer}
  - User creation: Auth trigger creates `public.users` row on signup

**Device Authentication:**
- XOR-encrypted MQTT payloads
  - Passkey: 18-byte cipher key per device (generated on claim, stored in NVS)
  - Checksum + timestamp validation (±8 second window for replay prevention)
  - Format: 19-byte binary (cmd, version, param, itemNumber, timestamp, padding, checksum)
  - Reference: `send-credit/index.ts` edge function, `xorDecodeWithPasskey()` in firmware

**Provisioning Flow:**
- SoftAP captive portal (HTTP) during initial WiFi setup
- `claim-device` edge function validates provisioning code, returns company/device/passkey

## Monitoring & Observability

**Error Tracking:**
- None configured (no Sentry, Rollbar, etc.)
- Database logging: PostgreSQL query logs to container stdout

**Logs:**
- Container logs: `docker compose logs -f [service]`
- Supabase Analytics: Logflare integration (optional, requires `LOGFLARE_*` API keys)
- Firmware diagnostics: `mdb_log` table stores MDB state changes (event-driven + 5min heartbeat)
- MDB log payload: plaintext JSON `{"state","addr","polls","chkErr","lastCmd"}`

## CI/CD & Deployment

**Hosting:**
- Self-hosted Docker (primary) - `Docker/docker-compose.yml` orchestrates all services
- Supabase CLI (local development) - `supabase start` for local development environment

**CI Pipeline:**
- GitHub Actions (optional) - Build/test via `.github/workflows/` (if present)
- Docker image registry: ghcr.io (GitHub Container Registry)
  - Frontend image: `ghcr.io/lucienkerl/mdb-esp32-cashless/frontend:latest`
  - Build args: `GIT_HASH`, `BUILD_DATE` passed to Dockerfile

**Deployment Path:**
- Frontend: Multi-stage Node build → SSR runtime on port 3000
- Edge functions: Deno files mounted from `Docker/supabase/functions/` → edge-runtime container
- Firmware: Binary in `firmware` storage bucket → OTA via `trigger-ota` function

## Environment Configuration

**Required env vars (Docker/.env):**
- **Secrets**: `POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `VAULT_ENC_KEY`, `PG_META_CRYPTO_KEY`
- **Database**: `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_PORT`
- **API**: `KONG_HTTP_PORT`, `SITE_URL`, `API_EXTERNAL_URL`
- **Auth**: `JWT_EXPIRY`, `DISABLE_SIGNUP`, `ENABLE_EMAIL_SIGNUP`, `ENABLE_EMAIL_AUTOCONFIRM`
- **SMTP**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_ADMIN_EMAIL`
- **MQTT**: `MQTT_HOST`, `MQTT_WEBHOOK_SECRET`, `MQTT_ADMIN_USER`, `MQTT_ADMIN_PASS`, `MQTT_PUBLIC_HOST`, `MQTT_PUBLIC_PORT`
- **Push**: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`
- **Optional**: `OPENAI_API_KEY`, `FCM_SERVICE_ACCOUNT_JSON`, `GITHUB_FIRMWARE_REPO`

**Secrets location:**
- Docker: `Docker/.env` (gitignored)
- Local Supabase: `Docker/supabase/.env` (gitignored)
- Production setup: `Docker/setup.sh` auto-generates secrets; `Docker/update.sh` handles existing installs

**Frontend runtime vars:**
- `NUXT_PUBLIC_SUPABASE_URL`: Passed to frontend container as `SUPABASE_URL` env
- `NUXT_PUBLIC_SUPABASE_KEY`: Passed as `SUPABASE_KEY`
- `NUXT_PUBLIC_VAPID_PUBLIC_KEY`: Passed as `VAPID_PUBLIC_KEY`
- `NUXT_PUBLIC_GITHUB_FIRMWARE_REPO`: Passed as `GITHUB_FIRMWARE_REPO`
- `SUPABASE_URL` in `management-frontend/.env` (dev local)

**Edge Function Configuration:**
- `Docker/supabase/config.toml` `[functions.<name>]` sections define per-function settings
- `[edge_runtime.secrets]` provides env vars to all functions via `Deno.env.get()`
- JWT verification: `verify_jwt = false` for all functions (workaround for local ES256 bug)

## Webhooks & Callbacks

**Incoming:**
- `claim-device` endpoint: Called by ESP32 firmware during provisioning
  - POST `{server_url}/functions/v1/claim-device` with `{short_code, mac_address}`
  - Returns `{company_id, device_id, passkey, mqtt_host, mqtt_port}`

- `mqtt-webhook` endpoint: Called by MQTT forwarder for all published events
  - POST `{SUPABASE_URL}/functions/v1/mqtt-webhook` with base64 payload + secret header
  - Decrypts XOR payloads, validates checksum/timestamp, writes to DB tables

**Outgoing:**
- MQTT publish: Edge functions publish to device topics (`credit`, `ota`, `config`)
- Email notifications: GoTrue SMTP (signup confirmations, password resets, invitations)
- Push notifications: VAPID web push + FCM native push (via edge function handlers)

## Data Flow: MQTT Sales Event Example

1. ESP32 vend completes → publishes XOR-encrypted binary to `/company_id/device_id/sale`
2. Mosquitto broker routes to forwarder subscriber
3. Forwarder decodes base64, POSTs to `mqtt-webhook` function with `X-Webhook-Secret` header
4. `mqtt-webhook` function (Deno):
   - Validates secret
   - Decrypts XOR payload with passkey from `embeddeds` table
   - Validates checksum + timestamp (±8s)
   - Inserts into `sales` table + triggers `decrement_tray_stock`
5. Supabase Realtime broadcasts schema change
6. Frontend (`useMachines()` composable) receives update via realtime subscription
7. Dashboard KPIs and machine detail page refresh

## Database Integration Details

**Multi-tenancy RLS Policies:**
- All tables have `company_id` column with RLS policy: `auth.uid() IN (SELECT user_id FROM organization_members WHERE company_id = ...)` or admin check
- Helper functions `my_company_id()` and `i_am_admin()` handle org lookups

**Triggers & Automation:**
- `decrement_tray_stock()` trigger fires on sales insert (auto-decrements `machine_trays.current_stock`)
- `deduct_warehouse_stock_fifo()` function handles warehouse FIFO stock deductions on refill operations
- Auth trigger `on_auth_user_created` (if present) inserts user record on signup

**Key Tables with External Data:**
- `embeddeds`: Device metadata + `passkey` for MQTT encryption
- `device_provisioning`: One-time claim codes (expires_at, used_at)
- `products`, `machine_trays`: Product catalog + machine slot configuration
- `sales`, `paxcounter`: Event stream from firmware
- `mdb_log`: MDB state-change diagnostics (plaintext JSON)
- `push_subscriptions`: Browser push endpoint + keys

---

*Integration audit: 2026-03-13*
