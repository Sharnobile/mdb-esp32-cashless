# mcp-bridge

Wraps the VMflow public REST API (`/api/v1`) as an MCP server (Streamable HTTP)
so MCP clients such as OpenClaw can auto-discover and call it as tools.

**Full setup & OpenClaw wiring:** [`docs/integrations/openclaw-mcp-bridge.md`](../../docs/integrations/openclaw-mcp-bridge.md)

## Files

- `server.py` — FastMCP `from_openapi` server. Loads the OpenAPI spec, forwards the
  inbound client's `X-API-Key` per request to the upstream API, applies the tool
  deny-list, serves Streamable HTTP at `$MCP_PATH`.
- `Dockerfile` — `python:3.12-slim` + `fastmcp`/`httpx`/`pyyaml`.
- `test_bridge.py` — smoke test for tool generation + the safety deny-list.

## Config (env)

| Var | Default | Purpose |
|---|---|---|
| `MCP_API_BASE_URL` | `http://kong:8000/api/v1/` | Upstream base URL — **trailing slash required**. |
| `MCP_OPENAPI_SPEC` | `/app/openapi.yaml` | Spec path (mounted from `supabase/functions/api-v1/openapi.yaml`). |
| `MCP_PATH` / `MCP_PORT` | `/mcp` / `8080` | MCP mount path and port. |
| `MCP_READONLY` | `false` | If true, expose only read (GET) tools. |
| `MCP_EXCLUDE_METHODS` | `DELETE,PATCH,PUT` | HTTP methods to hide. |
| `MCP_EXCLUDE_PATTERNS` | `^/actions/trigger-ota$,^/actions/send-config$` | Path regexes to hide. |

The bridge stores **no** API key — auth is the client's forwarded `X-API-Key`.

## Run the smoke test

```bash
docker build -t vmflow-mcp-bridge .
docker run -d --name mcp-test -p 18080:8080 \
  -v "$PWD/../supabase/functions/api-v1/openapi.yaml:/app/openapi.yaml:ro" \
  -v "$PWD/test_bridge.py:/app/test_bridge.py:ro" vmflow-mcp-bridge
docker exec mcp-test python test_bridge.py                  # default: 15 tools
docker exec -e MCP_READONLY=true mcp-test python test_bridge.py   # readonly: 11 tools
docker rm -f mcp-test
```
