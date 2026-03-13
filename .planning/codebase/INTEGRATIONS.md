# External Integrations

**Analysis Date:** 2026-03-13

## APIs & External Services

**Supabase Edge Functions:**
- 18 edge functions deployed via Deno runtime; all called via `useSupabaseClient().functions.invoke()`
- Location: `Docker/supabase/functions/`
- Authentication: JWT (from frontend) or API key (from external integrations)
- Key functions invoked from frontend:
  - `get-my-organization` - Fetch current user's organization + role (called on every protected page)
  - `create-provisioning-token` - Generate 8-char one-time device provisioning code
  - `send-credit` - Encrypt and publish credit via MQTT (admin only)
  - `trigger-ota` - Publish OTA firmware URL to device MQTT topic (admin only)
  - `import-products` - Bulk import products from Nayax Excel export
  - `create-api-key` - Generate API key for external integrations (admin only)
  - `import-github-release` - Fetch firmware releases from GitHub repo
  - Full list in `Docker/supabase/config.toml` `[functions.<name>]` sections

**MQTT Broker & Device Communication:**
- Service: Eclipse Mosquitto 2.1.2-alpine (port 1883)
- Topic format: `/{company_id}/{device_id}/{event}`
- Frontend → Device: Not directly; uses `send-credit` and `trigger-ota` edge functions to publish
- Device → Frontend: MQTT forwarder (`Docker/mqtt/forwarder/main.ts`) bridges to Supabase webhooks
- Forwarder subscribed topics: `/+/+/sale`, `/+/+/status`, `/+/+/paxcounter`, `/+/+/mdb-log`
- All payloads XOR-encrypted with 18-byte `passkey` (stored in `embeddeds` table)
- Frontend subscribes to realtime sales/status updates via Supabase Realtime (not MQTT directly)
- Credentials: vmflow/vmflow (devices), admin/admin (forwarder, edge functions)
- ACL: `Docker/mqtt/config/acl` defines per-user topic permissions

**Web Push Notifications (VAPID):**
- Standard: Web Push Protocol (RFC 8030)
- Keys: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` in Docker `.env`
- Frontend: `useNotifications()` composable calls `register-push` edge function
- Registration: `app/pages/settings.vue` → `register-push` → stores in `push_subscriptions` table
- Sending: `test-push` edge function invokes `_shared/web-push.ts` helper
- Implementation: `Docker/supabase/functions/_shared/web-push.ts`

**Firebase Cloud Messaging (Optional):**
- Opt-in: Set `FCM_SERVICE_ACCOUNT_JSON` in Docker `.env` (full service account key JSON)
- Purpose: Native iOS/Android push notifications (if app distributed via app stores)
- Fallback: Web push via VAPID works on all platforms (web only)
- Implementation: `_shared/web-push.ts` detects FCM availability and routes accordingly

**GitHub API:**
- Purpose: Fetch firmware release binaries for OTA updates
- Endpoint: https://api.github.com/repos/{owner}/{repo}/releases
- Opt-in: Set `GITHUB_FIRMWARE_REPO` env var (e.g., `myorg/firmware-releases`)
- Used in: `/firmware` page → `search-product-images` edge function (misnamed; actually imports GitHub releases)
- No authentication required (public repos only, subject to GitHub rate limits)

## Data Storage

**Databases:**
- **PostgreSQL 15.8.1** (via Supabase)
  - Connection: `postgres://postgres:password@db:5432/postgres`
  - Client: Supabase JS client (via PostgREST)
  - Tables: 20+ including `companies`, `embeddeds`, `sales`, `products`, `warehouse_stock_batches`, `mdb_log`, `push_subscriptions`, etc.
  - RLS enabled: All queries filtered by `my_company_id()` helper function
  - Migrations: Versioned SQL files in `Docker/supabase/migrations/`
  - Seed data: `Docker/supabase/seed.sql` (loaded on `supabase start`)

**File Storage:**
- **Supabase Storage** (v1.25.7):
  - Bucket: `product-images` (public, max 2 MiB per file, PNG/JPEG/WebP)
    - Used by: `useProducts()` composable (`uploadProductImage()`)
    - Path format: `{product_id}.{ext}` (e.g., `123e4567-e89b-12d3-a456-426614174000.png`)
    - Served at: `{SUPABASE_PUBLIC_URL}/storage/v1/object/public/product-images/{path}`
  - Bucket: `firmware` (public, max 5 MiB per file, .bin binaries)
    - Used by: `/firmware` page → `useFirmware()` composable
    - Manual upload via browser; consumed by ESP32 OTA flow
  - Image proxy: ImgProxy v3.8.0 (container) for transformations (resizing, WebP conversion)

**Caching:**
- None detected in management-frontend
- MQTT broker: Mosquitto (persists messages to disk at `Docker/mqtt/data/`)
- Browser: IndexedDB (Supabase Realtime maintains local state)
- App cache: PWA service worker (custom `public/sw.js`, no precache)

## Authentication & Identity

**Auth Provider:**
- **Supabase GoTrue v2.177.0** (self-hosted)
- Implementation: Email/password sign-up and login
- Endpoints: `auth/v1/signup`, `auth/v1/signin` (via Kong reverse proxy)
- JWT tokens: Stored in cookies (prefix: `sb-vmflow-auth-token-*`) and `localStorage`
- Token expiry: Configurable via `JWT_EXPIRY` env var (default 3600s = 1 hour)
- Frontend integration: `@nuxtjs/supabase` provides `useSupabaseUser()` and `useSupabaseAuth()`

**Multi-Tenancy:**
- Model: `organization_members(company_id, user_id, role)`
- Roles: `admin` or `viewer`
- Auth trigger: On new user signup, `on_auth_user_created` trigger inserts into `public.users` table
- RLS: All queries filtered via `my_company_id()` (reads from `organization_members`)

**API Key Authentication (Optional):**
- Location: `api_keys` table (one per external integration)
- Usage: `send-credit` and other edge functions accept `X-API-Key` header
- Security: Keys stored as SHA-256 hashes (`key_hash` column)
- Prefix: 8-char prefix stored (e.g., `sk_live_abc12345...` prefix is `abc12345`)
- Revocation: `revoked_at` timestamp; middleware checks and rejects revoked keys

## Monitoring & Observability

**Error Tracking:**
- Not detected in frontend code
- No Sentry, Rollbar, or similar integration

**Logs:**
- **Console logging:** `console.log/error/warn` throughout composables (e.g., `useMachines()`)
- **Supabase logs:** Docker container logs: `docker compose logs -f functions`, `docker compose logs -f db`
- **MQTT broker logs:** `docker compose logs -f broker`
- **Analytics (optional):** Logflare integration in docker-compose (disabled by default)
  - Requires `LOGFLARE_PRIVATE_ACCESS_TOKEN` env var

**Performance:**
- No explicit APM (Application Performance Monitoring) detected
- Realtime lag: Browser DevTools Network tab shows WebSocket connections to Supabase Realtime
- Database query performance: Visible in PostgreSQL slow query log (if enabled)

## CI/CD & Deployment

**Hosting:**
- **Production:** Docker Compose on a single host (Linux server recommended)
  - All services in `Docker/docker-compose.yml`
  - Frontend runs on port 3000 (behind reverse proxy for HTTPS)
- **Local Development:** Docker Compose + Supabase CLI (`supabase start`)
- **Container Registry:** GitHub Container Registry (`ghcr.io/lucienkerl/mdb-esp32-cashless/frontend:latest`)

**CI Pipeline:**
- Not detected in repo (no `.github/workflows/` checked in)
- Manual build: `docker compose build` from `Docker/` directory

**OTA Firmware Updates:**
- Device receives binary URL via MQTT topic `/{company_id}/{device_id}/ota`
- URL points to: Supabase Storage `firmware` bucket or GitHub release
- Device downloads and flashes via `esp_https_ota_begin()`
- No delta/patch updates (full binary only)

## Environment Configuration

**Required env vars (Docker/.env):**
- `POSTGRES_PASSWORD` - DB password (32+ chars)
- `JWT_SECRET` - JWT signing key (32+ chars)
- `ANON_KEY` - Supabase public JWT (generated)
- `SERVICE_ROLE_KEY` - Supabase service JWT (generated)
- `MQTT_WEBHOOK_SECRET` - Shared secret between forwarder and edge functions (32+ chars)
- `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` - Generated by `setup.sh`
- `SUPABASE_PUBLIC_URL` - Public API gateway URL (e.g., `http://10.0.1.181:8000` for LAN, `https://api.vmflow.xyz` for prod)
- `MQTT_PUBLIC_HOST`, `MQTT_PUBLIC_PORT` - Public MQTT address returned to devices (LAN IP or domain)
- `API_EXTERNAL_URL` - For GoTrue redirect callbacks (e.g., `http://localhost:8000`)
- `SITE_URL` - For auth email links (e.g., `http://localhost:3000` or `https://vmflow.xyz`)
- Optional: `GITHUB_FIRMWARE_REPO`, `FCM_SERVICE_ACCOUNT_JSON`, `OPENAI_API_KEY`

**Secrets location:**
- `Docker/.env` - All secrets generated here by `setup.sh`
- NVS (ESP32): Firmware stores `passkey`, `mqtt_host`, `mqtt_port` in device non-volatile storage
- Database: `api_keys` table stores hashed API keys for external integrations

## Webhooks & Callbacks

**Incoming:**
- **MQTT → Supabase:** Deno forwarder (`Docker/mqtt/forwarder/main.ts`)
  - Subscribes to `/+/+/sale`, `/+/+/status`, `/+/+/paxcounter`, `/+/+/mdb-log` topics
  - Forwards raw payloads (base64-encoded) to `mqtt-webhook` edge function via HTTP POST
  - Header: `X-Webhook-Secret` (matches `MQTT_WEBHOOK_SECRET` env var)
  - Response: `mqtt-webhook` decrypts XOR payloads, validates checksum + timestamp (±8s window), writes to DB

**Outgoing:**
- **Supabase → Device (MQTT):** Edge functions publish via `_shared/mqtt-publish.ts`
  - Topics: `/{company_id}/{device_id}/credit`, `/{company_id}/{device_id}/ota`, `/{company_id}/{device_id}/config`
  - Payloads: XOR-encrypted binary format (19 bytes: cmd + version + param + itemNumber + timestamp + padding + checksum)
  - Functions: `send-credit`, `trigger-ota`, `send-device-config` edge functions
- **Frontend → Push:** Browser push subscriptions
  - Endpoint: User's push service endpoint (managed by browser)
  - Payload: Encrypted via VAPID; sent by `test-push` edge function

---

*Integration audit: 2026-03-13*
