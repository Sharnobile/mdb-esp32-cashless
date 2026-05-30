# scripts/

## sync-prod-to-dev.sh

Refreshes the **local Supabase CLI dev database** with **production data** so you
develop against realistic data. It clones prod `auth.users`/`auth.identities` +
all `public` data + `product-images`, so you log into dev with your **production
credentials**. Design: `docs/superpowers/specs/2026-05-29-prod-to-dev-data-sync-design.md`.

### Prerequisites
- A running local stack: `cd Docker && supabase start`
- Tools on PATH: `docker`, `ssh`, `rsync`, `curl`, `supabase` (no local `psql` needed)
- SSH access to the prod server

### Setup
```bash
cp scripts/sync-prod-to-dev.env.example scripts/sync-prod-to-dev.env
# edit scripts/sync-prod-to-dev.env (PROD_SSH, PROD_DIR, PROD_STORAGE_DIR)
```

### Run
```bash
./scripts/sync-prod-to-dev.sh            # prompts before replacing dev data
./scripts/sync-prod-to-dev.sh --dry-run  # preview, touches nothing
./scripts/sync-prod-to-dev.sh --skip-images
./scripts/sync-prod-to-dev.sh --yes      # unattended (cron)
```
After it finishes, log in at http://localhost:3000 with your prod email/password.

### Safety
- Prod is **read-only** (pg_dump + rsync only).
- The restore can only target the local CLI container (`supabase_db_<project_id>`
  from `Docker/supabase/config.toml`) — it cannot point at a remote DB.
- The restore is one transaction; any error rolls back and leaves dev untouched.
- It does **not** use `supabase db reset`.

### Scheduling (optional — a refresh overwrites local data, so opt in deliberately)
cron (weekly, Mon 04:00):
```cron
# 0 4 * * 1 cd /path/to/mdb-esp32-cashless && ./scripts/sync-prod-to-dev.sh --yes >> tmp/sync/cron.log 2>&1
```
macOS launchd: create `~/Library/LaunchAgents/com.vmflow.syncprod.plist` with a
`StartCalendarInterval` and `ProgramArguments` of `[/bin/bash, -lc, "cd /path && ./scripts/sync-prod-to-dev.sh --yes"]`,
then `launchctl load` it.

### Auth column-skew fallback
If a sync fails on the `auth.users`/`auth.identities` COPY (because prod runs a
newer GoTrue than your CLI), update your CLI (`supabase` upgrade) so the dev
schema is a superset of prod, then re-run. If you cannot upgrade, replace the
`--table=auth.users`/`--table=auth.identities` dumps with explicit-column
`\copy (SELECT <cols>) TO STDOUT` / `\copy <t>(<cols>) FROM STDIN` using the
stable column lists in the design spec (§ Assumptions & accepted risks).
