"""Smoke test for the VMflow MCP bridge.

Builds the server from the real OpenAPI spec and lists the generated MCP tools
over the in-memory protocol, asserting the safety deny-list behaves correctly.

Run inside the image, e.g.:
    docker exec mcp-test python test_bridge.py
    docker exec -e MCP_READONLY=true mcp-test python test_bridge.py
"""

import asyncio
import os

from fastmcp import Client

import server  # importing builds server.mcp from the env config


async def main() -> None:
    async with Client(server.mcp) as client:
        tools = await client.list_tools()

    names = [t.name.lower() for t in tools]
    print("TOOL_COUNT", len(tools))
    for t in tools:
        first_line = (t.description or "").splitlines()[0] if t.description else ""
        print("TOOL", t.name, "|", first_line[:60])

    readonly = os.environ.get("MCP_READONLY", "false").lower() in ("1", "true", "yes", "on")

    assert len(tools) > 0, "no tools generated from the spec"

    # Safety: the destructive device actions must never be exposed (check tool names,
    # not descriptions — read tools legitimately mention words like "created").
    assert not any("ota" in n for n in names), "trigger-ota tool leaked into the tool list!"
    assert not any("configuration" in n for n in names), "send-config tool leaked into the tool list!"

    if readonly:
        # Only read (GET) tools survive; every write verb is gone.
        assert not any(n.startswith(("create", "update", "delete", "send")) for n in names), (
            "a write tool survived readonly mode: %s" % names
        )
    else:
        assert any(n.startswith("send") for n in names), "send-credit should be available in default mode"
        assert any("machine" in n and n.startswith("list") for n in names), "read tools should be available"

    print("RESULT OK readonly=%s tools=%d" % (readonly, len(tools)))


if __name__ == "__main__":
    asyncio.run(main())
