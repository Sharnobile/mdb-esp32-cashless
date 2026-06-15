"""
VMflow OpenAPI -> MCP bridge.

Wraps the existing public REST API (`/api/v1`, served by the `api-v1` edge
function) as a Model Context Protocol server using FastMCP, so MCP clients such
as OpenClaw can auto-discover and call the API's operations as tools.

Auth model: NO API key is stored in this container. The inbound MCP client must
send an `X-API-Key` header; we forward it per request to the upstream API. The
`api-v1` gateway validates it (company-scoped, rate-limited). Revoking the key in
the dashboard instantly cuts access.

Transport: Streamable HTTP at $MCP_PATH (default /mcp). Reachable only through the
Kong route /mcp -> http://mcp-bridge:8080/mcp; never published to the host.

Configuration (all via env, sensible defaults baked in):
  MCP_OPENAPI_SPEC     Path to the OpenAPI spec file (default /app/openapi.yaml,
                       mounted from Docker/supabase/functions/api-v1/openapi.yaml)
  MCP_API_BASE_URL     Upstream base URL. MUST end with a trailing slash so httpx
                       appends the operation path instead of replacing it.
                       (default http://kong:8000/api/v1/)
  MCP_PATH             HTTP mount path for the MCP endpoint (default /mcp)
  MCP_HOST / MCP_PORT  Bind address (default 0.0.0.0 / 8080)
  MCP_READONLY         If true, exclude every write operation (POST/PUT/PATCH/
                       DELETE) — only read (GET) tools are exposed (default false)
  MCP_EXCLUDE_METHODS  Comma-separated HTTP methods to hide as a safety net
                       (default DELETE,PATCH,PUT — the spec has none today, but
                       this keeps destructive verbs hidden if the spec grows)
  MCP_EXCLUDE_PATTERNS Comma-separated path regexes to hide. Default hides the
                       two destructive device actions while keeping send-credit:
                       ^/actions/trigger-ota$,^/actions/send-config$
"""

import os
import sys

import httpx
import yaml

from fastmcp import FastMCP
from fastmcp.server.dependencies import get_http_request
from starlette.requests import Request as StarletteRequest
from starlette.responses import PlainTextResponse

# The RouteMap / MCPType import location has moved between FastMCP releases.
try:
    from fastmcp.server.openapi import RouteMap, MCPType
except ImportError:  # pragma: no cover - fallback for newer package layouts
    from fastmcp.server.providers.openapi import RouteMap, MCPType


API_KEY_HEADER = "X-API-Key"


def _env(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def _bool(value: str) -> bool:
    return value.strip().lower() in ("1", "true", "yes", "on")


def _csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


SPEC_PATH = _env("MCP_OPENAPI_SPEC", "/app/openapi.yaml")
API_BASE_URL = _env("MCP_API_BASE_URL", "http://kong:8000/api/v1/")
MOUNT_PATH = _env("MCP_PATH", "/mcp")
HOST = _env("MCP_HOST", "0.0.0.0")
PORT = int(_env("MCP_PORT", "8080"))
READONLY = _bool(_env("MCP_READONLY", "false"))
EXCLUDE_METHODS = [m.upper() for m in _csv(_env("MCP_EXCLUDE_METHODS", "DELETE,PATCH,PUT"))]
EXCLUDE_PATTERNS = _csv(_env("MCP_EXCLUDE_PATTERNS", r"^/actions/trigger-ota$,^/actions/send-config$"))


async def forward_api_key(request: httpx.Request) -> None:
    """httpx request hook (must be async for httpx.AsyncClient): copy the inbound
    MCP client's X-API-Key onto the outgoing upstream call. No-op when there is no
    HTTP request in context (so it is safe during startup / non-HTTP transports)."""
    try:
        inbound = get_http_request()
    except RuntimeError:
        return
    # Starlette headers are case-insensitive.
    api_key = inbound.headers.get(API_KEY_HEADER)
    if api_key:
        request.headers[API_KEY_HEADER] = api_key


def build_route_maps() -> list[RouteMap]:
    """Build the tool deny-list. Everything in the spec becomes a tool unless a
    rule excludes it."""
    maps: list[RouteMap] = []
    if READONLY:
        maps.append(
            RouteMap(methods=["POST", "PUT", "PATCH", "DELETE"], pattern=r".*", mcp_type=MCPType.EXCLUDE)
        )
        return maps
    if EXCLUDE_METHODS:
        maps.append(RouteMap(methods=EXCLUDE_METHODS, pattern=r".*", mcp_type=MCPType.EXCLUDE))
    for pattern in EXCLUDE_PATTERNS:
        maps.append(RouteMap(pattern=pattern, mcp_type=MCPType.EXCLUDE))
    return maps


def load_spec(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def build_server() -> FastMCP:
    spec = load_spec(SPEC_PATH)
    client = httpx.AsyncClient(
        base_url=API_BASE_URL,
        timeout=httpx.Timeout(30.0),
        event_hooks={"request": [forward_api_key]},
    )
    return FastMCP.from_openapi(
        openapi_spec=spec,
        client=client,
        name="VMflow API",
        route_maps=build_route_maps(),
    )


mcp = build_server()


@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_request: StarletteRequest) -> PlainTextResponse:
    return PlainTextResponse("ok")


if __name__ == "__main__":
    print(
        f"[mcp-bridge] upstream={API_BASE_URL} path={MOUNT_PATH} readonly={READONLY} "
        f"exclude_methods={EXCLUDE_METHODS} exclude_patterns={EXCLUDE_PATTERNS}",
        file=sys.stderr,
    )
    mcp.run(transport="http", host=HOST, port=PORT, path=MOUNT_PATH)
