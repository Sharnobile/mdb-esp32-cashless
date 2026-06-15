FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py ./

# Streamable-HTTP MCP endpoint, served at $MCP_PATH (default /mcp) on port 8080.
# Reachable only via the Kong route /mcp -> http://mcp-bridge:8080/mcp; never
# published to the host.
EXPOSE 8080

CMD ["python", "server.py"]
