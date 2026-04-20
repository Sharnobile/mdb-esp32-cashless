FROM denoland/deno:2.2.2
WORKDIR /app
COPY main.ts .
RUN deno cache main.ts
# /data holds the Deno-KV dead-letter queue (dlq.db). Mounted as a named
# volume in docker-compose so it survives forwarder restarts and outlives
# broker retention for long-running Supabase outages.
RUN mkdir -p /data
VOLUME ["/data"]
# --unstable-kv: Deno KV is a stable product but still requires the flag in Deno 2.2
CMD ["deno", "run", "--allow-net", "--allow-env", "--allow-read=/data", "--allow-write=/data", "--unstable-kv", "main.ts"]
