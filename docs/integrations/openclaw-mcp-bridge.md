# Connecting OpenClaw (and other MCP clients) to the VMflow API

This guide connects an [OpenClaw](https://docs.openclaw.ai/) agent to the VMflow
backend so it can **read data and make changes through the public REST API**,
auto-discovering the available operations as MCP tools.

It works with any MCP client that speaks **Streamable HTTP** (Claude Desktop,
Cursor, etc.), not just OpenClaw.

## How it works

VMflow already publishes a machine-readable API: the public REST API at `/api/v1`
(gateway: `Docker/supabase/functions/api-v1/index.ts`) with an OpenAPI 3.0 spec at
`GET /api/v1/openapi.yaml`. The **`mcp-bridge`** compose service wraps that spec as
an MCP server (FastMCP), so an MCP client points at one URL and discovers every
operation as a tool.

```
OpenClaw (remote)
  │ Streamable HTTP (HTTPS), header  X-API-Key: vmf_…
  ▼
host reverse proxy   supabase.<domain>:443 → kong:8000      (already exists)
  ▼
Kong route  /mcp  →  mcp-bridge:8080/mcp                    (this feature)
  │ forwards the same X-API-Key per request
  ▼
Kong route  /api/v1  →  functions:9000/api-v1  →  validates key → PostgREST / actions
```

**Auth model:** the bridge stores **no** API key. Each client sends its own
`X-API-Key`, which the bridge forwards per request to `/api/v1`. The gateway
validates it (company-scoped, rate-limited). Revoke the key in the dashboard to
cut access instantly. A request with no/invalid key gets a `401` from the API.

## What gets exposed

Tools are generated from the OpenAPI spec, so the bridge is least-privilege by
construction (the spec only documents the operations below — no raw deletes/updates).

| Default (15 tools) | Read | Write |
|---|---|---|
| machines, sales, products, categories, devices, trays, warehouses, stock-batches, paxcounter, activity-log | ✅ list/get | create machine / product / tray |
| send-credit | | ✅ |
| **trigger-ota, send-config** | | 🚫 **hidden by default** (destructive device actions) |

- **Read-only mode:** set `MCP_READONLY=true` (compose env) to expose only the 11
  GET tools — no creates, no send-credit.
- **Adjust the deny-list:** `MCP_EXCLUDE_PATTERNS` is a comma-separated list of
  path regexes (default `^/actions/trigger-ota$,^/actions/send-config$`). To also
  hide `send-credit`, add `^/actions/send-credit$`.

---

## Step 1 — Create an API key

In the management dashboard: **Settings → API Keys → create** (admin only). Copy
the `vmf_…` key — it's shown once. It is company-scoped and rate-limited
(100 req/min by default).

## Step 2 — Deploy the bridge

The `mcp-bridge` service and its Kong route ship in `docker-compose.yml` /
`Docker/volumes/api/kong.yml`.

- **Existing installs:** `Docker/update.sh` builds the bridge, starts it, and
  reloads Kong automatically (it detects the `kong.yml` change).
- **Manual / first run:**
  ```bash
  cd Docker
  docker compose up -d --build mcp-bridge
  docker compose restart kong          # load the new /mcp route
  ```

The bridge is never published to the host; it's reachable only through Kong.

## Step 3 — Verify the endpoint

```bash
# Internal health (from the Docker host):
docker compose exec mcp-bridge python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/healthz').read())"

# Public MCP endpoint (should return HTTP 200, not 404/502):
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://supabase.<your-domain>/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'X-API-Key: vmf_your_key' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

## Step 4 — Register in OpenClaw

Easiest is the CLI (writes the correct `~/.openclaw/openclaw.json` entry), then
restart the gateway:

```bash
openclaw mcp add vmflow \
  --url https://supabase.<your-domain>/mcp \
  --transport streamable-http \
  --header "X-API-Key: vmf_your_key"
```

Equivalent `~/.openclaw/openclaw.json` entry (schema may vary slightly by version):

```jsonc
{
  "mcpServers": {
    "vmflow": {
      "transport": "streamable-http",
      "url": "https://supabase.<your-domain>/mcp",
      "headers": { "X-API-Key": "vmf_your_key" }
    }
  }
}
```

Restart the OpenClaw gateway, then confirm discovery:

```bash
openclaw mcp list      # should show "vmflow" + the discovered tools
```

Ask your agent something like *"list my vending machines"* (read) or
*"create a product called Test"* (write) to confirm end-to-end.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `401 unauthorized` on every tool | Missing/invalid/revoked `X-API-Key`. Check the header value; confirm the key isn't revoked in Settings → API Keys. |
| `429 rate_limited` | Default 100 req/min per key. Back off; the response carries `retry_after`. Raise `api_keys.rate_limit` for the key if needed. |
| `502` on `/mcp` after deploy | Kong cached a DNS miss before `mcp-bridge` existed. `docker compose restart kong`. |
| Streaming responses hang / arrive late | Disable response buffering for `/mcp` at the **host** reverse proxy. nginx: `location /mcp { proxy_buffering off; proxy_read_timeout 3600s; ... }`. Caddy streams by default. |
| Tools missing / extra | Check `MCP_READONLY` and `MCP_EXCLUDE_PATTERNS`; the spec at `Docker/supabase/functions/api-v1/openapi.yaml` is the source of truth. |
| Bridge won't start | `docker compose logs mcp-bridge`. Most likely the spec mount path or a FastMCP version mismatch. |

## Security notes

- The public `/mcp` endpoint is protected by the **same `X-API-Key`** as the API —
  no separate secret, nothing stored in the container.
- Keep destructive tools hidden (default) unless an agent genuinely needs them;
  prefer `MCP_READONLY=true` for read-only assistants.
- The key grants the agent the same access a dashboard API key has for that
  company. Scope per use case by creating separate keys, and revoke when done.
- Local dev (Supabase CLI, not this compose stack): run the bridge image standalone
  with `MCP_API_BASE_URL=http://host.docker.internal:54321/api/v1/` to point at the
  CLI API.
