# Public REST API Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a public REST API (`/api/v1/`) with API key authentication that proxies to PostgREST for CRUD and to existing edge functions for device actions, with OpenAPI/Swagger documentation.

**Architecture:** A single `api-v1` edge function acts as gateway — validates API keys, mints short-lived JWTs with company claims, and proxies requests to PostgREST (CRUD) or existing edge functions (actions). Existing RLS policies enforce company isolation. A DB migration extends `my_company_id()` and `i_am_admin()` to recognize API-key JWTs via `COALESCE`/`OR` in `LANGUAGE sql`.

**Tech Stack:** Deno edge functions, PostgreSQL (LANGUAGE sql functions, views), PostgREST, Kong API gateway, `jose` JWT library, OpenAPI 3.0

**Spec:** `docs/superpowers/specs/2026-04-16-public-rest-api-design.md`

---

## Chunk 1: Foundation — Database Migration, Config, Shared Utility

### Task 1: Database Migration

**Files:**
- Create: `Docker/supabase/migrations/20260417000000_api_gateway_auth.sql`

- [ ] **Step 1: Create migration file**

Create `Docker/supabase/migrations/20260417000000_api_gateway_auth.sql`:

```sql
-- Extend RLS helpers to support API-key JWTs (from api-v1 gateway).
-- CRITICAL: both functions stay LANGUAGE sql STABLE for RLS inlining.
-- See docs/superpowers/specs/2026-04-16-public-rest-api-design.md

-- 1. my_company_id() — add COALESCE fallback to api_company_id JWT claim
CREATE OR REPLACE FUNCTION my_company_id() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    (SELECT company_id FROM organization_members WHERE user_id = auth.uid() LIMIT 1),
    (current_setting('request.jwt.claims', true)::json->>'api_company_id')::uuid
  )
$$;

-- 2. i_am_admin() — also recognise api_key_id JWT claim as admin
CREATE OR REPLACE FUNCTION i_am_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT
    EXISTS (
      SELECT 1 FROM organization_members
      WHERE user_id = auth.uid() AND role = 'admin'
    )
    OR (current_setting('request.jwt.claims', true)::json->>'api_key_id') IS NOT NULL
$$;

-- 3. View hiding passkey from API consumers
CREATE OR REPLACE VIEW api_embeddeds AS
SELECT
  id, company, subdomain, mac_address, status, status_at,
  mdb_diagnostics, created_at, last_restart_reason,
  last_restart_at, online_since
FROM embeddeds;

-- 4. Grant view access to authenticated role (PostgREST needs this)
GRANT SELECT ON api_embeddeds TO authenticated;

-- 5. Configurable rate limit per API key (requests per minute)
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS rate_limit integer DEFAULT 100;
```

- [ ] **Step 2: Apply migration**

Run: `cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase && supabase migration up`
Expected: Migration applied successfully, no errors.

- [ ] **Step 3: Verify functions remain LANGUAGE sql**

Run: `cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase && supabase db lint`
Expected: No lint errors. Both functions still `LANGUAGE sql STABLE`.

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/migrations/20260417000000_api_gateway_auth.sql
git commit -m "feat: add API gateway auth migration — extend RLS helpers for API keys"
```

---

### Task 2: Configuration — config.toml and Kong

**Files:**
- Modify: `Docker/supabase/config.toml` (add function entry + JWT_SECRET secret)
- Modify: `Docker/volumes/api/kong.yml` (add `/api/v1` route)

- [ ] **Step 1: Add `[functions.api-v1]` to config.toml**

Add after the last `[functions.*]` block (after `[functions.deal-search]`):

```toml
[functions.api-v1]
enabled = true
verify_jwt = false
import_map = "./functions/api-v1/deno.json"
entrypoint = "./functions/api-v1/index.ts"
```

**Note:** `JWT_SECRET` does NOT need to be added to `[edge_runtime.secrets]`. The Supabase CLI auto-injects it, and Docker compose already passes it via the `functions` service environment. Adding it with `env()` syntax could override the auto-injected value with an empty string.

- [ ] **Step 2: Add Kong route for `/api/v1`**

Add to `Docker/volumes/api/kong.yml` in the `services:` array, BEFORE the dashboard catch-all (before line 228 `## Protected Dashboard`):

```yaml
  ## Public REST API (api-v1 gateway)
  - name: api-v1
    _comment: 'API Gateway: /api/v1/* -> http://functions:9000/api-v1/*'
    url: http://functions:9000/api-v1
    routes:
      - name: api-v1-all
        strip_path: true
        paths:
          - /api/v1
    plugins:
      - name: cors
        config:
          origins:
            - '*'
          methods:
            - GET
            - POST
            - PATCH
            - DELETE
            - OPTIONS
          headers:
            - Content-Type
            - X-API-Key
          exposed_headers:
            - X-Total-Count
          max_age: 3600
```

- [ ] **Step 3: Commit**

```bash
git add Docker/supabase/config.toml Docker/volumes/api/kong.yml
git commit -m "feat: add Kong route and edge function config for api-v1 gateway"
```

---

### Task 3: Shared API Key Auth Utility

**Files:**
- Create: `Docker/supabase/functions/_shared/api-key-auth.ts`

The `hashKey` function is duplicated in `send-credit/index.ts` (line 12) and `create-api-key/index.ts` (line 11). Extract it to a shared utility for the gateway and future functions.

- [ ] **Step 1: Create shared utility**

Create `Docker/supabase/functions/_shared/api-key-auth.ts`:

```typescript
/**
 * Shared API key authentication helpers.
 * Used by: api-v1 gateway, send-credit, create-api-key
 */

/** SHA-256 hash an API key to hex string for db lookup. */
export async function hashKey(key: string): Promise<string> {
  const encoded = new TextEncoder().encode(key)
  const hash = await crypto.subtle.digest('SHA-256', encoded)
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

/**
 * Validate an API key against the api_keys table.
 * Returns { id, company_id, rate_limit } on success, or throws with status + message.
 *
 * @param apiKey  The raw API key from X-API-Key header
 * @param adminClient  Supabase client with service_role (bypasses RLS)
 */
export async function validateApiKey(
  apiKey: string,
  adminClient: { from: (table: string) => any },
): Promise<{ id: string; company_id: string; rate_limit: number }> {
  const keyHash = await hashKey(apiKey)

  const { data: keyData, error: keyError } = await adminClient
    .from('api_keys')
    .select('id, company_id, revoked_at, rate_limit')
    .eq('key_hash', keyHash)
    .maybeSingle()

  if (keyError || !keyData) {
    throw Object.assign(new Error('Invalid API key'), { status: 401 })
  }
  if (keyData.revoked_at) {
    throw Object.assign(new Error('API key has been revoked'), { status: 401 })
  }

  // Fire-and-forget: update last_used_at
  adminClient
    .from('api_keys')
    .update({ last_used_at: new Date().toISOString() })
    .eq('id', keyData.id)
    .then(() => {}, () => {})

  return {
    id: keyData.id,
    company_id: keyData.company_id,
    rate_limit: keyData.rate_limit ?? 100,
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add Docker/supabase/functions/_shared/api-key-auth.ts
git commit -m "feat: extract shared API key auth utility"
```

---

## Chunk 2: Gateway Core — Auth, JWT, PostgREST Proxy

### Task 4: API Gateway Edge Function — Deno Setup

**Files:**
- Create: `Docker/supabase/functions/api-v1/deno.json`

- [ ] **Step 1: Create deno.json**

Create `Docker/supabase/functions/api-v1/deno.json`:

```json
{ "imports": {} }
```

- [ ] **Step 2: Commit**

```bash
git add Docker/supabase/functions/api-v1/deno.json
git commit -m "chore: add deno.json for api-v1 edge function"
```

---

### Task 5: API Gateway — Core Implementation

**Files:**
- Create: `Docker/supabase/functions/api-v1/index.ts`

This is the main gateway. It handles: API key validation → JWT minting → route dispatch (PostgREST proxy for CRUD, action proxy for device commands, docs for Swagger UI).

- [ ] **Step 1: Create the gateway edge function**

Create `Docker/supabase/functions/api-v1/index.ts`:

```typescript
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import * as jose from 'https://deno.land/x/jose@v4.14.4/index.ts'
import { validateApiKey } from '../_shared/api-key-auth.ts'

// ── Constants ───────────────────────────────────────────────────────────────

const FUNCTION_PREFIX = '/api-v1'

/** Allowlist: API path → PostgREST table/view name. Unlisted paths → 404. */
const CRUD_ROUTES: Record<string, { table: string; readOnly: boolean }> = {
  machines:        { table: 'vendingMachine', readOnly: false },
  sales:           { table: 'sales',          readOnly: true },
  products:        { table: 'products',       readOnly: false },
  categories:      { table: 'product_category', readOnly: false },
  devices:         { table: 'api_embeddeds',  readOnly: true },
  trays:           { table: 'machine_trays',  readOnly: false },
  warehouses:      { table: 'warehouses',     readOnly: false },
  'stock-batches': { table: 'warehouse_stock_batches', readOnly: false },
  paxcounter:      { table: 'paxcounter',     readOnly: true },
  'activity-log':  { table: 'activity_log',   readOnly: true },
}

/** Action endpoints → target edge function name. */
const ACTION_ROUTES: Record<string, string> = {
  'send-credit':  'send-credit',
  'trigger-ota':  'trigger-ota',
  'send-config':  'send-device-config',
}

const JWT_TTL_SECONDS = 60

// ── Rate limiter (best-effort in-memory) ────────────────────────────────────

const rateLimitMap = new Map<string, number[]>()

function checkRateLimit(keyId: string, limit: number): { allowed: boolean; retryAfter: number } {
  const now = Date.now()
  const windowMs = 60_000
  const timestamps = (rateLimitMap.get(keyId) ?? []).filter((t) => now - t < windowMs)

  if (timestamps.length >= limit) {
    const oldestInWindow = timestamps[0]
    const retryAfter = Math.ceil((oldestInWindow + windowMs - now) / 1000)
    return { allowed: false, retryAfter }
  }

  timestamps.push(now)
  rateLimitMap.set(keyId, timestamps)
  return { allowed: true, retryAfter: 0 }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function errorResponse(
  error: string,
  message: string,
  status: number,
  extra?: Record<string, unknown>,
): Response {
  return jsonResponse({ error, message, ...extra }, status)
}

/**
 * Parse the request path into a resource name and optional ID.
 * Input path from edge runtime: `/api-v1/machines/some-uuid`
 * Returns: { resource: 'machines', id: 'some-uuid' | null }
 */
function parsePath(pathname: string): { resource: string; id: string | null; subpath: string | null } {
  const stripped = pathname.replace(FUNCTION_PREFIX, '').replace(/^\/+/, '')
  const segments = stripped.split('/').filter(Boolean)
  return {
    resource: segments[0] ?? '',
    id: segments[1] ?? null,
    subpath: segments.length > 2 ? segments.slice(1).join('/') : null,
  }
}

/**
 * Mint a short-lived JWT that PostgREST trusts.
 * Contains api_company_id + api_key_id so my_company_id() / i_am_admin() work.
 */
async function mintJwt(
  apiKeyId: string,
  companyId: string,
  secret: string,
): Promise<string> {
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )

  const now = Math.floor(Date.now() / 1000)
  return await new jose.SignJWT({
    role: 'authenticated',
    api_company_id: companyId,
    api_key_id: apiKeyId,
    iss: 'vmflow-api-gateway',
  })
    .setSubject(apiKeyId)
    .setIssuedAt(now)
    .setExpirationTime(now + JWT_TTL_SECONDS)
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .sign(key)
}

// ── Main handler ────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const url = new URL(req.url)
  const { resource, id, subpath } = parsePath(url.pathname)

  // ── CORS preflight ──
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204 })
  }

  // ── Public documentation endpoints (no auth) ──
  if (resource === 'docs') {
    return serveSwaggerUI()
  }
  if (resource === 'openapi.yaml') {
    return serveOpenApiSpec()
  }

  // ── API key authentication ──
  const apiKey = req.headers.get('X-API-Key')
  if (!apiKey) {
    return errorResponse(
      'unauthorized',
      'Missing X-API-Key header. Obtain a key from the management dashboard at /api-keys.',
      401,
    )
  }

  const adminClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  let keyInfo: { id: string; company_id: string; rate_limit: number }
  try {
    keyInfo = await validateApiKey(apiKey, adminClient)
  } catch (err: any) {
    return errorResponse('unauthorized', err.message, err.status ?? 401)
  }

  // ── Rate limiting ──
  const rl = checkRateLimit(keyInfo.id, keyInfo.rate_limit)
  if (!rl.allowed) {
    return errorResponse(
      'rate_limit_exceeded',
      `Rate limit of ${keyInfo.rate_limit} requests per minute exceeded.`,
      429,
      { retry_after: rl.retryAfter },
    )
  }

  // ── Route: Actions ──
  if (resource === 'actions' && id) {
    const fnName = ACTION_ROUTES[id]
    if (!fnName) {
      return errorResponse('not_found', `Unknown action: ${id}`, 404)
    }
    return proxyAction(req, fnName, keyInfo.company_id, apiKey)
  }

  // ── Route: CRUD via PostgREST ──
  const route = CRUD_ROUTES[resource]
  if (!route) {
    return errorResponse('not_found', `Unknown resource: ${resource}. Available: ${Object.keys(CRUD_ROUTES).join(', ')}`, 404)
  }

  if (route.readOnly && req.method !== 'GET') {
    return errorResponse(
      'forbidden',
      `Resource '${resource}' is read-only. Only GET requests are allowed.`,
      403,
    )
  }

  return proxyCrud(req, url, route.table, id, keyInfo)
})

// ── PostgREST CRUD proxy ────────────────────────────────────────────────────

async function proxyCrud(
  req: Request,
  url: URL,
  table: string,
  resourceId: string | null,
  keyInfo: { id: string; company_id: string },
): Promise<Response> {
  const jwtSecret = Deno.env.get('JWT_SECRET')
  if (!jwtSecret) {
    return errorResponse('internal_error', 'JWT_SECRET not configured', 500)
  }

  const jwt = await mintJwt(keyInfo.id, keyInfo.company_id, jwtSecret)
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!

  // Build PostgREST URL
  // PostgREST is at http://rest:3000 inside Docker network.
  // NOTE: This hardcoded URL only works in Docker compose. For local dev
  // via `supabase functions serve`, PostgREST proxy won't connect.
  // Use Docker compose for full integration testing.
  let postgrestPath = `/${table}`

  // Convenience: /machines/<uuid> → ?id=eq.<uuid>
  const queryParams = new URLSearchParams(url.search)
  let singleResource = false
  if (resourceId) {
    queryParams.set('id', `eq.${resourceId}`)
    if (req.method === 'GET') {
      // Return singular object (PostgREST Accept header)
      singleResource = true
    }
  }

  const postgrestUrl = `http://rest:3000${postgrestPath}?${queryParams.toString()}`

  const headers: Record<string, string> = {
    Authorization: `Bearer ${jwt}`,
    apikey: anonKey,
  }

  // Forward relevant request headers
  const contentType = req.headers.get('Content-Type')
  if (contentType) headers['Content-Type'] = contentType

  const prefer = req.headers.get('Prefer')
  if (prefer) headers['Prefer'] = prefer

  // For single resource GET, request singular response
  if (singleResource) {
    headers['Accept'] = 'application/vnd.pgrst.object+json'
  }

  const body = req.method !== 'GET' && req.method !== 'HEAD'
    ? await req.text()
    : undefined

  try {
    const response = await fetch(postgrestUrl, {
      method: req.method,
      headers,
      body,
    })

    // Pass through PostgREST response with appropriate headers
    const responseHeaders = new Headers()
    responseHeaders.set('Content-Type', response.headers.get('Content-Type') ?? 'application/json')

    // Forward pagination headers
    const contentRange = response.headers.get('Content-Range')
    if (contentRange) responseHeaders.set('Content-Range', contentRange)

    return new Response(await response.text(), {
      status: response.status,
      headers: responseHeaders,
    })
  } catch (err: any) {
    return errorResponse('internal_error', `Proxy error: ${err.message}`, 502)
  }
}

// ── Action proxy ────────────────────────────────────────────────────────────

async function proxyAction(
  req: Request,
  functionName: string,
  companyId: string,
  originalApiKey: string,
): Promise<Response> {
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!

  const body = await req.text()

  // send-credit already supports X-API-Key natively — forward it directly.
  // trigger-ota and send-device-config use service-role + X-Company-Id pattern.
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (functionName === 'send-credit') {
    headers['X-API-Key'] = originalApiKey
  } else {
    headers['Authorization'] = `Bearer ${serviceRoleKey}`
    headers['X-Company-Id'] = companyId
  }

  try {
    const response = await fetch(`${supabaseUrl}/functions/v1/${functionName}`, {
      method: 'POST',
      headers,
      body,
    })

    const responseBody = await response.text()
    return new Response(responseBody, {
      status: response.status,
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (err: any) {
    return errorResponse('internal_error', `Action proxy error: ${err.message}`, 502)
  }
}

// ── Documentation endpoints ─────────────────────────────────────────────────

function serveSwaggerUI(): Response {
  const publicUrl = Deno.env.get('PUBLIC_SUPABASE_URL') || Deno.env.get('SUPABASE_URL') || ''
  const specUrl = `${publicUrl}/api/v1/openapi.yaml`

  // NOTE: v1 loads Swagger UI from CDN (unpkg.com). On-premise installations
  // without internet will see a broken docs page. Future: bundle assets locally.
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>VMflow API v1</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
  <style>body { margin: 0; } .topbar { display: none; }</style>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    SwaggerUIBundle({
      url: '${specUrl}',
      dom_id: '#swagger-ui',
      deepLinking: true,
      presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
      layout: 'BaseLayout',
    })
  </script>
</body>
</html>`

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  })
}

function serveOpenApiSpec(): Response {
  // Read the spec file from the function directory
  try {
    const spec = Deno.readTextFileSync(new URL('./openapi.yaml', import.meta.url).pathname)
    return new Response(spec, {
      headers: {
        'Content-Type': 'text/yaml; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
      },
    })
  } catch (_) {
    return errorResponse('not_found', 'OpenAPI spec not found', 404)
  }
}
```

- [ ] **Step 2: Verify the function starts without errors**

Run (from Docker directory with supabase running):
```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase && supabase functions serve api-v1 --no-verify-jwt
```
Expected: Function starts successfully, no import errors.

- [ ] **Step 3: Commit**

```bash
git add Docker/supabase/functions/api-v1/index.ts
git commit -m "feat: add api-v1 gateway edge function — auth, JWT, PostgREST proxy, rate limiting"
```

---

## Chunk 3: Action Routing — Modify Existing Edge Functions

### Task 6: Modify `trigger-ota` to Accept Service-Role + Company Context

**Files:**
- Modify: `Docker/supabase/functions/trigger-ota/index.ts`

Currently `trigger-ota` only accepts user JWT auth (line 9-21). The API gateway calls it with `Authorization: Bearer <SERVICE_ROLE_KEY>` plus `X-Company-Id` header. We need to detect this alternative auth path.

- [ ] **Step 1: Add service-role + X-Company-Id auth path**

In `Docker/supabase/functions/trigger-ota/index.ts`, replace the auth block (lines 8-21) with dual auth support:

Replace:
```typescript
    // Authenticate the caller via their JWT
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    );

    // Verify the user is an admin
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      });
    }
```

With:
```typescript
    // ── Authenticate caller ─────────────────────────────────────────────────
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const authHeader = req.headers.get('Authorization') ?? ''
    const token = authHeader.replace('Bearer ', '')
    const companyIdHeader = req.headers.get('X-Company-Id')

    let userId: string | null = null
    let companyId: string | null = null

    // Path 1: Service-role call from API gateway (X-Company-Id present)
    if (token === serviceRoleKey && companyIdHeader) {
      companyId = companyIdHeader
    } else {
      // Path 2: Normal user JWT
      const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get('SUPABASE_ANON_KEY')!,
        { global: { headers: { Authorization: authHeader } } }
      );
      const { data: { user }, error: authError } = await supabase.auth.getUser();
      if (authError || !user) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        });
      }
      userId = user.id
    }
```

- [ ] **Step 2: Update device lookup to use companyId from either path**

Replace the device lookup block (lines 29-34) that uses `supabase` (user-scoped client) with the `adminClient` (which was already created at line 24-27):

Replace:
```typescript
    // Look up the target device
    const { data: device, error: deviceError } = await supabase
      .from("embeddeds")
      .select("id, company, status")
      .eq("id", body.device_id)
      .single();
```

With:
```typescript
    // Look up the target device (use admin client, filter by company)
    // Resolve companyId from user JWT if not from gateway
    if (!companyId && userId) {
      const { data: membership } = await adminClient
        .from('organization_members')
        .select('company_id')
        .eq('user_id', userId)
        .maybeSingle()
      companyId = membership?.company_id ?? null
    }
    if (!companyId) {
      return new Response(JSON.stringify({ error: 'Could not resolve company' }), {
        status: 403, headers: { 'Content-Type': 'application/json' },
      });
    }

    const { data: device, error: deviceError } = await adminClient
      .from("embeddeds")
      .select("id, company, status")
      .eq("id", body.device_id)
      .eq("company", companyId)
      .single();
```

- [ ] **Step 3: Update firmware lookup to use adminClient**

Replace the firmware lookup (lines 43-47) to also use `adminClient`:

Replace:
```typescript
    const { data: firmware, error: fwError } = await supabase
      .from("firmware_versions")
      .select("id, file_path, version_label")
      .eq("id", body.firmware_id)
      .single();
```

With:
```typescript
    const { data: firmware, error: fwError } = await adminClient
      .from("firmware_versions")
      .select("id, file_path, version_label")
      .eq("id", body.firmware_id)
      .single();
```

- [ ] **Step 4: Update OTA record to handle nullable userId**

At line 85, `triggered_by: user.id` must handle the case where `userId` is null (API gateway call):

Replace:
```typescript
        triggered_by: user.id,
```

With:
```typescript
        triggered_by: userId,
```

- [ ] **Step 5: Remove the now-unused user-scoped supabase variable**

Remove the `supabase` client creation from the non-gateway path — it's only created inside the `else` block now, so the `supabase` variable used later in lines 30, 43 needs to be replaced with `adminClient`. After steps 2-4, all references to `supabase` should be replaced with `adminClient`, so the standalone `supabase` variable from the `else` block can stay scoped there.

- [ ] **Step 6: Commit**

```bash
git add Docker/supabase/functions/trigger-ota/index.ts
git commit -m "feat: trigger-ota accepts service-role + X-Company-Id for API gateway"
```

---

### Task 7: Modify `send-device-config` to Accept Service-Role + Company Context

**Files:**
- Modify: `Docker/supabase/functions/send-device-config/index.ts`

Currently uses JWT auth at lines 88-120. Add service-role + X-Company-Id as alternative.

- [ ] **Step 1: Add service-role auth path**

In `Docker/supabase/functions/send-device-config/index.ts`, replace the auth block (lines 88-120):

Replace:
```typescript
    // ── Authenticate caller ─────────────────────────────────────────────────
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Authorization required' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }

    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Verify admin role ───────────────────────────────────────────────────
    const { data: membership } = await adminClient
      .from('organization_members')
      .select('company_id, role')
      .eq('user_id', user.id)
      .maybeSingle()

    if (!membership || membership.role !== 'admin') {
      return new Response(JSON.stringify({ error: 'Admin role required' }), {
        status: 403, headers: { 'Content-Type': 'application/json' },
      })
    }
```

With:
```typescript
    // ── Authenticate caller ─────────────────────────────────────────────────
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Authorization required' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }

    const token = authHeader.replace('Bearer ', '')
    const companyIdHeader = req.headers.get('X-Company-Id')
    let companyId: string | null = null
    let userId: string | null = null

    // Path 1: Service-role call from API gateway
    if (token === Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') && companyIdHeader) {
      companyId = companyIdHeader
    } else {
      // Path 2: Normal user JWT
      const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
      if (userError || !user) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        })
      }
      userId = user.id

      const { data: membership } = await adminClient
        .from('organization_members')
        .select('company_id, role')
        .eq('user_id', user.id)
        .maybeSingle()

      if (!membership || membership.role !== 'admin') {
        return new Response(JSON.stringify({ error: 'Admin role required' }), {
          status: 403, headers: { 'Content-Type': 'application/json' },
        })
      }
      companyId = membership.company_id
    }
```

- [ ] **Step 2: Update device lookup to use resolved companyId**

Replace line 127 (`eq('company', membership.company_id)`) with `eq('company', companyId)`:

Replace:
```typescript
      .eq('company', membership.company_id)
```

With:
```typescript
      .eq('company', companyId)
```

- [ ] **Step 3: Update activity log to use resolved userId**

Replace line 169 (`user_id: user.id`) with nullable userId:

Replace:
```typescript
        user_id: user.id,
```

With:
```typescript
        user_id: userId,
```

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/functions/send-device-config/index.ts
git commit -m "feat: send-device-config accepts service-role + X-Company-Id for API gateway"
```

---

## Chunk 4: OpenAPI Specification

### Task 8: Create OpenAPI Spec

**Files:**
- Create: `Docker/supabase/functions/api-v1/openapi.yaml`

- [ ] **Step 1: Create the OpenAPI specification**

Create `Docker/supabase/functions/api-v1/openapi.yaml`:

```yaml
openapi: '3.0.3'
info:
  title: VMflow API
  version: '1.0'
  description: |
    Public REST API for VMflow vending machine management.

    ## Authentication
    All endpoints (except `/api/v1/docs`) require an API key via the `X-API-Key` header.
    Create API keys in the management dashboard under **Settings → API Keys**.

    ## Query Syntax (PostgREST)
    CRUD endpoints support PostgREST query parameters:

    | Operator | Example | Description |
    |----------|---------|-------------|
    | `eq` | `?status=eq.online` | Equals |
    | `neq` | `?status=neq.offline` | Not equals |
    | `gt` / `gte` | `?created_at=gte.2026-01-01` | Greater than (or equal) |
    | `lt` / `lte` | `?item_price=lt.5` | Less than (or equal) |
    | `like` | `?name=like.*cola*` | Pattern match (case-sensitive) |
    | `ilike` | `?name=ilike.*cola*` | Pattern match (case-insensitive) |
    | `in` | `?status=in.(online,offline)` | In list |
    | `is` | `?revoked_at=is.null` | IS NULL / IS NOT NULL |

    **Ordering:** `?order=created_at.desc`
    **Pagination:** `?limit=20&offset=40`
    **Column selection:** `?select=id,name,price`

    ## Rate Limiting
    Default: 100 requests per minute per API key. When exceeded, the API returns
    `429 Too Many Requests` with a `retry_after` field (seconds).

servers:
  - url: '{baseUrl}/api/v1'
    variables:
      baseUrl:
        default: 'http://localhost:8000'
        description: Your VMflow server URL

security:
  - ApiKeyAuth: []

paths:
  /machines:
    get:
      summary: List machines
      tags: [Machines]
      parameters:
        - $ref: '#/components/parameters/limit'
        - $ref: '#/components/parameters/offset'
        - $ref: '#/components/parameters/order'
        - $ref: '#/components/parameters/select'
      responses:
        '200':
          description: Array of machines
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Machine'
        '401':
          $ref: '#/components/responses/Unauthorized'
        '429':
          $ref: '#/components/responses/RateLimited'
    post:
      summary: Create a machine
      tags: [Machines]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/MachineCreate'
      responses:
        '201':
          description: Created
        '401':
          $ref: '#/components/responses/Unauthorized'

  /machines/{id}:
    get:
      summary: Get a single machine
      tags: [Machines]
      parameters:
        - $ref: '#/components/parameters/resourceId'
      responses:
        '200':
          description: Machine object
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Machine'
        '404':
          $ref: '#/components/responses/NotFound'

  /sales:
    get:
      summary: List sales (read-only)
      tags: [Sales]
      description: Sales records are read-only. They are created automatically when a vending machine reports a sale via MQTT.
      parameters:
        - $ref: '#/components/parameters/limit'
        - $ref: '#/components/parameters/offset'
        - $ref: '#/components/parameters/order'
        - $ref: '#/components/parameters/select'
      responses:
        '200':
          description: Array of sales
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Sale'

  /products:
    get:
      summary: List products
      tags: [Products]
      parameters:
        - $ref: '#/components/parameters/limit'
        - $ref: '#/components/parameters/offset'
        - $ref: '#/components/parameters/order'
        - $ref: '#/components/parameters/select'
      responses:
        '200':
          description: Array of products
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Product'
    post:
      summary: Create a product
      tags: [Products]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/ProductCreate'
      responses:
        '201':
          description: Created

  /categories:
    get:
      summary: List product categories
      tags: [Products]
      responses:
        '200':
          description: Array of categories
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Category'

  /devices:
    get:
      summary: List devices (read-only)
      tags: [Devices]
      description: |
        Returns registered embedded devices. Sensitive fields (passkey, MQTT credentials)
        are hidden. Devices are read-only via the API — they are provisioned via the
        management dashboard.
      parameters:
        - $ref: '#/components/parameters/limit'
        - $ref: '#/components/parameters/offset'
      responses:
        '200':
          description: Array of devices
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Device'

  /trays:
    get:
      summary: List machine trays/slots
      tags: [Trays]
      parameters:
        - $ref: '#/components/parameters/limit'
        - $ref: '#/components/parameters/offset'
      responses:
        '200':
          description: Array of trays
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Tray'
    post:
      summary: Create a tray
      tags: [Trays]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/TrayCreate'
      responses:
        '201':
          description: Created

  /warehouses:
    get:
      summary: List warehouses
      tags: [Warehouse]
      responses:
        '200':
          description: Array of warehouses
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Warehouse'

  /stock-batches:
    get:
      summary: List stock batches (FIFO)
      tags: [Warehouse]
      responses:
        '200':
          description: Array of stock batches
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/StockBatch'

  /paxcounter:
    get:
      summary: List paxcounter data (read-only)
      tags: [Analytics]
      description: Visitor traffic counts from ESP32 paxcounter sensors.
      parameters:
        - $ref: '#/components/parameters/limit'
        - $ref: '#/components/parameters/offset'
        - $ref: '#/components/parameters/order'
      responses:
        '200':
          description: Array of paxcounter entries
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/PaxCounter'

  /activity-log:
    get:
      summary: List activity log (read-only)
      tags: [Analytics]
      parameters:
        - $ref: '#/components/parameters/limit'
        - $ref: '#/components/parameters/offset'
        - $ref: '#/components/parameters/order'
      responses:
        '200':
          description: Array of activity log entries

  /actions/send-credit:
    post:
      summary: Send credit to a device
      tags: [Actions]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [device_id, amount]
              properties:
                device_id:
                  type: string
                  format: uuid
                amount:
                  type: number
                  description: Credit amount in EUR
                  example: 1.50
      responses:
        '200':
          description: Credit sent
        '404':
          $ref: '#/components/responses/NotFound'

  /actions/trigger-ota:
    post:
      summary: Trigger OTA firmware update
      tags: [Actions]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [device_id, firmware_id]
              properties:
                device_id:
                  type: string
                  format: uuid
                firmware_id:
                  type: string
                  format: uuid
      responses:
        '200':
          description: OTA triggered

  /actions/send-config:
    post:
      summary: Send device configuration
      tags: [Actions]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [device_id, config]
              properties:
                device_id:
                  type: string
                  format: uuid
                config:
                  type: object
                  properties:
                    restart:
                      type: boolean
                      description: Remote restart the device
                    mdb_address:
                      type: integer
                      enum: [1, 2]
                      description: MDB address (1 or 2)
                    mdb_reset:
                      type: boolean
                      description: Soft MDB reset
      responses:
        '200':
          description: Config sent

components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
      description: API key created in the management dashboard

  parameters:
    resourceId:
      name: id
      in: path
      required: true
      schema:
        type: string
        format: uuid
    limit:
      name: limit
      in: query
      schema:
        type: integer
        default: 20
      description: Max rows to return
    offset:
      name: offset
      in: query
      schema:
        type: integer
        default: 0
      description: Number of rows to skip
    order:
      name: order
      in: query
      schema:
        type: string
      description: 'Sort order, e.g. `created_at.desc`'
    select:
      name: select
      in: query
      schema:
        type: string
      description: 'Comma-separated column list, e.g. `id,name,price`'

  responses:
    Unauthorized:
      description: Missing or invalid API key
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Error'
    NotFound:
      description: Resource not found
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Error'
    RateLimited:
      description: Rate limit exceeded
      content:
        application/json:
          schema:
            allOf:
              - $ref: '#/components/schemas/Error'
              - type: object
                properties:
                  retry_after:
                    type: integer
                    description: Seconds until next request is allowed

  schemas:
    Error:
      type: object
      properties:
        error:
          type: string
        message:
          type: string

    Machine:
      type: object
      properties:
        id:
          type: string
          format: uuid
        company:
          type: string
          format: uuid
        name:
          type: string
        location:
          type: string
        created_at:
          type: string
          format: date-time

    MachineCreate:
      type: object
      required: [name]
      properties:
        name:
          type: string
        location:
          type: string

    Sale:
      type: object
      properties:
        id:
          type: string
          format: uuid
        embedded_id:
          type: string
          format: uuid
        item_price:
          type: number
          description: Price in EUR (not cents)
        item_number:
          type: integer
        channel:
          type: string
        product_id:
          type: string
          format: uuid
        created_at:
          type: string
          format: date-time

    Product:
      type: object
      properties:
        id:
          type: string
          format: uuid
        company:
          type: string
          format: uuid
        name:
          type: string
        price:
          type: number
        image_path:
          type: string
        discontinued:
          type: boolean

    ProductCreate:
      type: object
      required: [name]
      properties:
        name:
          type: string
        price:
          type: number
        category:
          type: string
          format: uuid

    Category:
      type: object
      properties:
        id:
          type: string
          format: uuid
        company:
          type: string
          format: uuid
        name:
          type: string

    Device:
      type: object
      properties:
        id:
          type: string
          format: uuid
        company:
          type: string
          format: uuid
        subdomain:
          type: integer
        mac_address:
          type: string
        status:
          type: string
        status_at:
          type: string
          format: date-time
        online_since:
          type: string
          format: date-time

    Tray:
      type: object
      properties:
        id:
          type: string
          format: uuid
        machine_id:
          type: string
          format: uuid
        item_number:
          type: integer
        product_id:
          type: string
          format: uuid
        capacity:
          type: integer
        current_stock:
          type: integer

    TrayCreate:
      type: object
      required: [machine_id, item_number]
      properties:
        machine_id:
          type: string
          format: uuid
        item_number:
          type: integer
        product_id:
          type: string
          format: uuid
        capacity:
          type: integer

    Warehouse:
      type: object
      properties:
        id:
          type: string
          format: uuid
        company_id:
          type: string
          format: uuid
        name:
          type: string

    StockBatch:
      type: object
      properties:
        id:
          type: string
          format: uuid
        warehouse_id:
          type: string
          format: uuid
        product_id:
          type: string
          format: uuid
        quantity:
          type: integer
        expires_at:
          type: string
          format: date-time

    PaxCounter:
      type: object
      properties:
        id:
          type: string
          format: uuid
        embedded_id:
          type: string
          format: uuid
        count:
          type: integer
        created_at:
          type: string
          format: date-time
```

- [ ] **Step 2: Commit**

```bash
git add Docker/supabase/functions/api-v1/openapi.yaml
git commit -m "feat: add OpenAPI 3.0 spec for VMflow public API"
```

---

## Chunk 5: Integration Testing

### Task 9: End-to-End Integration Test

**Prerequisites:** Docker services running (`docker compose up`), at least one company with an API key created.

- [ ] **Step 1: Verify docs endpoint (no auth)**

```bash
# Swagger UI should load without auth
curl -s http://localhost:8000/api/v1/docs | head -5
```
Expected: HTML containing `<title>VMflow API v1</title>`

```bash
# OpenAPI spec should return YAML
curl -s http://localhost:8000/api/v1/openapi.yaml | head -3
```
Expected: `openapi: '3.0.3'`

- [ ] **Step 2: Verify auth rejection**

```bash
# No API key → 401
curl -s http://localhost:8000/api/v1/machines | jq .error
```
Expected: `"unauthorized"`

```bash
# Invalid key → 401
curl -s -H "X-API-Key: vmf_invalid" http://localhost:8000/api/v1/machines | jq .error
```
Expected: `"unauthorized"`

- [ ] **Step 3: Verify CRUD read (machines)**

```bash
# Create a test API key first (via management UI or directly)
# Then test with that key:
API_KEY="vmf_your_test_key_here"

curl -s -H "X-API-Key: $API_KEY" http://localhost:8000/api/v1/machines | jq '.[0].id'
```
Expected: A valid UUID (or empty array if no machines)

- [ ] **Step 4: Verify read-only enforcement**

```bash
# POST to read-only endpoint → 403
curl -s -X POST -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
  http://localhost:8000/api/v1/sales -d '{}' | jq .error
```
Expected: `"forbidden"`

- [ ] **Step 5: Verify unknown resource → 404**

```bash
curl -s -H "X-API-Key: $API_KEY" http://localhost:8000/api/v1/users | jq .error
```
Expected: `"not_found"`

- [ ] **Step 6: Verify filtering and pagination**

```bash
# Sales with limit and order
curl -s -H "X-API-Key: $API_KEY" \
  "http://localhost:8000/api/v1/sales?limit=5&order=created_at.desc" | jq 'length'
```
Expected: At most 5

- [ ] **Step 7: Verify devices endpoint hides passkey**

```bash
curl -s -H "X-API-Key: $API_KEY" http://localhost:8000/api/v1/devices | jq '.[0] | keys'
```
Expected: Keys should NOT include `passkey`. Should include `id`, `company`, `mac_address`, `status`, etc.

- [ ] **Step 8: Verify single resource convenience syntax**

```bash
# Get a machine ID first
MACHINE_ID=$(curl -s -H "X-API-Key: $API_KEY" http://localhost:8000/api/v1/machines?limit=1 | jq -r '.[0].id')

# Single resource → returns object, not array
curl -s -H "X-API-Key: $API_KEY" "http://localhost:8000/api/v1/machines/$MACHINE_ID" | jq 'type'
```
Expected: `"object"` (not `"array"`)

- [ ] **Step 9: Commit all remaining changes and verify clean state**

```bash
git status
# Should show no uncommitted changes
```
