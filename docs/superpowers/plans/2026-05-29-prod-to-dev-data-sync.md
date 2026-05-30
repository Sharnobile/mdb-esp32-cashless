# Prod → Dev Data Sync Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A repeatable, guarded bash script that refreshes the local Supabase CLI dev database with production data (cloning prod auth so dev login uses prod credentials, plus product images).

**Architecture:** One bash script (`scripts/sync-prod-to-dev.sh`) split into small pure helper functions (unit-tested) and integration functions (SSH dump from prod → atomic data-only restore into the dev DB container via `docker exec psql` → re-upload product images through the dev Storage API). A `main` guarded by a sourced-vs-executed check lets a plain-bash test file source and unit-test the pure helpers. Everything destructive runs inside one transaction under `session_replication_role = replica`.

**Tech Stack:** Bash (must run on macOS system bash 3.2 — no bash-4-only features), `docker`, `ssh`, `rsync`, `curl`, Supabase CLI, Postgres `pg_dump`/`psql` (invoked *inside* containers, not on the host).

**Reference spec:** `docs/superpowers/specs/2026-05-29-prod-to-dev-data-sync-design.md`

---

## Prerequisites & conventions

- **No git worktree** — per project preference, work directly on the current branch (create a feature branch only when committing, if the user asks).
- **Portability:** target macOS system bash 3.2. Do **not** use `${var,,}`, `declare -A`, `mapfile`/`readarray`, or other bash-4+ features. Lowercasing is done via `tr`. Loops that must mutate outer variables use process substitution (`while read; do …; done < <(…)`), never a pipe-into-`while`.
- **Supabase project dir** is `Docker/` (it contains `supabase/config.toml`), so `supabase` CLI commands run via `(cd "$REPO_ROOT/Docker" && supabase …)`.
- The integration functions (SSH/docker/rsync/curl) are **not** unit-tested — they require a live prod server and dev stack. They are verified via a `--dry-run` preview and the end-to-end acceptance run (Task 11). Only the pure helpers get TDD unit tests; this is called out per task.
- **Supabase CLI `.env` parse quirk (2026-05-30, resolved in the script — no `.env` change needed):** the Bun-based `supabase` CLI (v2.101.0) parses `Docker/supabase/.env` **strictly line-by-line in its cwd-resolution path** and fails with `ProjectEnvParseError` on the multi-line PEM `APNS_PRIVATE_KEY` (the value is already double-quoted — quoting does NOT help this parser). The **`--workdir` invocation path does not** trigger that parse. **Resolution:** the script calls `supabase --workdir "$SUPABASE_PROJECT_DIR" …` for both `migration up` (preflight) and `status -o env` (upload_images) instead of `(cd … && supabase …)`. The secret/`.env` is untouched; `web-push.ts:624` passes the key straight into the APNS signer, so it must stay a real multi-line PEM. Verified: the full `--dry-run` completes end-to-end (`migration up` → "Local database is up to date", dev row counts printed). The `cd`-form shown in the Task 5/Task 8 code blocks below is the pre-fix version; the shipped script uses `--workdir`. (Earlier confusion came from a direct `supabase --workdir … status` happening to work, which masked the cwd-path failure that the script's original `cd` form hit.)

## File Structure

| File | Responsibility | Created in |
|---|---|---|
| `scripts/sync-prod-to-dev.sh` | The whole tool: flag parsing, pure helpers, integration phases, `main`. Sourced-guard at the bottom so tests can load helpers without running `main`. | Tasks 1–9 |
| `scripts/sync-prod-to-dev.env.example` | Documented config template (copied to the gitignored `.env`). | Task 10 |
| `scripts/test/test-sync-helpers.sh` | Plain-bash unit tests for the pure helpers. | Tasks 1–4 |
| `scripts/test/fixtures/config.toml` | Fixture for `dev_db_container`. | Task 2 |
| `scripts/test/fixtures/good-dump.sql` / `bad-dump.txt` / `empty.sql` | Fixtures for `dump_looks_like_sql`. | Task 3 |
| `scripts/README.md` | Usage, prerequisites, safety, scheduling (cron/launchd), auth-skew fallback note. | Task 10 |
| `.gitignore` | Add `tmp/sync/` and `scripts/sync-prod-to-dev.env`. | Task 1 |

The single-script layout is deliberate: the tool is ~200 lines of cohesive orchestration; splitting it across files would hurt readability more than help. The pure helpers are factored as functions (not files) and tested by sourcing.

---

## Chunk 1: Scaffolding & unit-tested pure helpers

### Task 1: Script skeleton, gitignore, test harness, and `mime_for` (TDD)

**Files:**
- Create: `scripts/sync-prod-to-dev.sh`
- Create: `scripts/test/test-sync-helpers.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Add gitignore entries**

Append to `.gitignore`:

```gitignore

# Prod→dev data sync (scripts/sync-prod-to-dev.sh)
tmp/sync/
scripts/sync-prod-to-dev.env
```

- [ ] **Step 2: Create the script skeleton with the sourced-guard**

Create `scripts/sync-prod-to-dev.sh` (this is the base everything else is added to):

```bash
#!/usr/bin/env bash
# sync-prod-to-dev.sh — refresh the local Supabase CLI dev DB with production data.
# Design: docs/superpowers/specs/2026-05-29-prod-to-dev-data-sync-design.md
# Portable to macOS system bash 3.2 — no bash-4-only features.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_TOML="$REPO_ROOT/Docker/supabase/config.toml"
SUPABASE_PROJECT_DIR="$REPO_ROOT/Docker"
ENV_FILE="$SCRIPT_DIR/sync-prod-to-dev.env"
WORKDIR="$REPO_ROOT/tmp/sync"

# Flag defaults
ASSUME_YES=false
CLEAN_CACHE=false
KEEP_DUMPS=false
SKIP_IMAGES=false
DRY_RUN=false

# DEV_DB_CONTAINER is resolved in preflight()
DEV_DB_CONTAINER=""

# ---------- pure helpers (unit-tested in scripts/test/test-sync-helpers.sh) ----------

mime_for() {
  # $1 = filename/object name → echoes a Content-Type
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.png)        echo "image/png" ;;
    *.jpg|*.jpeg) echo "image/jpeg" ;;
    *.webp)       echo "image/webp" ;;
    *)            echo "application/octet-stream" ;;
  esac
}

# ---------- entry point ----------

main() {
  echo "main not yet implemented" >&2
  exit 1
}

# Only run main when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 3: Write the failing test for `mime_for`**

Create `scripts/test/test-sync-helpers.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for the pure helpers in sync-prod-to-dev.sh.
# Run: bash scripts/test/test-sync-helpers.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../sync-prod-to-dev.sh"   # sourced → main() is NOT executed
set +e   # disable -e so failed assertions don't abort the run

pass=0; fail=0
check() { # $1=desc $2=actual $3=expected
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   - $1";
  else fail=$((fail+1)); echo "NOT OK - $1: got [$2] expected [$3]"; fi
}
check_rc() { # $1=desc $2=actual_rc $3=expected_rc
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   - $1";
  else fail=$((fail+1)); echo "NOT OK - $1: rc got [$2] expected [$3]"; fi
}

# --- mime_for ---
check "mime png"        "$(mime_for foo.png)"  "image/png"
check "mime PNG upper"  "$(mime_for FOO.PNG)"  "image/png"
check "mime jpg"        "$(mime_for a.jpg)"    "image/jpeg"
check "mime jpeg"       "$(mime_for a.jpeg)"   "image/jpeg"
check "mime webp"       "$(mime_for a.webp)"   "image/webp"
check "mime fallback"   "$(mime_for a.bin)"    "application/octet-stream"

echo "----"
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 4: Run the test to verify `mime_for` passes (and the harness works)**

Run: `bash scripts/test/test-sync-helpers.sh`
Expected: all `mime_*` lines print `ok`, final line `passed: 6, failed: 0`, exit code 0.

(If `mime_for` were missing, sourcing would still succeed but the checks would print `NOT OK` / empty output — confirming the test actually exercises the function.)

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-prod-to-dev.sh scripts/test/test-sync-helpers.sh .gitignore
git commit -m "feat(sync): script skeleton + mime_for helper with unit test"
```

---

### Task 2: `dev_db_container` helper (TDD)

**Files:**
- Modify: `scripts/sync-prod-to-dev.sh` (add helper after `mime_for`)
- Create: `scripts/test/fixtures/config.toml`
- Modify: `scripts/test/test-sync-helpers.sh` (add assertions)

- [ ] **Step 1: Create the fixture**

Create `scripts/test/fixtures/config.toml`:

```toml
# minimal fixture for dev_db_container()
project_id = "test-project"

[db]
port = 54322
```

- [ ] **Step 2: Write the failing test**

Add to `scripts/test/test-sync-helpers.sh` before the `echo "----"` summary:

```bash
# --- dev_db_container ---
check "container from fixture" "$(dev_db_container "$HERE/fixtures/config.toml")" "supabase_db_test-project"
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash scripts/test/test-sync-helpers.sh`
Expected: `NOT OK - container from fixture: got [] expected [supabase_db_test-project]` (function not defined → empty output), final `failed: 1`, exit 1.

- [ ] **Step 4: Implement `dev_db_container`**

Add to `scripts/sync-prod-to-dev.sh` after `mime_for`:

```bash
dev_db_container() {
  # $1 = path to config.toml → echoes the local CLI db container name
  local cfg="$1" pid
  pid="$(grep -E '^[[:space:]]*project_id' "$cfg" | head -n1 | cut -d'"' -f2)"
  if [[ -z "$pid" ]]; then
    echo "ERROR: project_id not found in $cfg" >&2
    return 1
  fi
  echo "supabase_db_${pid}"
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash scripts/test/test-sync-helpers.sh`
Expected: `ok   - container from fixture`, `failed: 0`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/sync-prod-to-dev.sh scripts/test/test-sync-helpers.sh scripts/test/fixtures/config.toml
git commit -m "feat(sync): dev_db_container resolves local container from config.toml"
```

---

### Task 3: `dump_looks_like_sql` helper (TDD)

**Files:**
- Modify: `scripts/sync-prod-to-dev.sh`
- Create: `scripts/test/fixtures/good-dump.sql`, `scripts/test/fixtures/bad-dump.txt`, `scripts/test/fixtures/empty.sql`
- Modify: `scripts/test/test-sync-helpers.sh`

- [ ] **Step 1: Create fixtures**

`scripts/test/fixtures/good-dump.sql`:

```sql
--
-- PostgreSQL database dump
--
SET statement_timeout = 0;
SELECT pg_catalog.set_config('search_path', '', false);
```

`scripts/test/fixtures/bad-dump.txt` (simulates an SSH/compose error landing in the file instead of SQL):

```text
Error response from daemon: container not running
```

`scripts/test/fixtures/empty.sql`: create as an empty file (`: > scripts/test/fixtures/empty.sql`).

- [ ] **Step 2: Write the failing tests**

Add to `scripts/test/test-sync-helpers.sh` before the summary:

```bash
# --- dump_looks_like_sql ---
dump_looks_like_sql "$HERE/fixtures/good-dump.sql"; check_rc "good dump accepted" "$?" "0"
dump_looks_like_sql "$HERE/fixtures/bad-dump.txt"; check_rc "bad dump rejected"  "$?" "1"
dump_looks_like_sql "$HERE/fixtures/empty.sql";    check_rc "empty dump rejected" "$?" "1"
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash scripts/test/test-sync-helpers.sh`
Expected: the three `dump_*` checks fail (function not defined returns 127 → `rc got [127]`), `failed: 3`, exit 1.

- [ ] **Step 4: Implement `dump_looks_like_sql`**

Add to `scripts/sync-prod-to-dev.sh` after `dev_db_container`:

```bash
dump_looks_like_sql() {
  # $1 = path to a dump file. Returns 0 if it looks like pg_dump SQL output.
  local f="$1" line
  [[ -s "$f" ]] || return 1
  line="$(grep -m1 -vE '^[[:space:]]*$' "$f" 2>/dev/null || true)"
  [[ "$line" =~ ^(SET|SELECT|--|\\) ]]
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash scripts/test/test-sync-helpers.sh`
Expected: the three `dump_*` checks print `ok`, `failed: 0`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/sync-prod-to-dev.sh scripts/test/test-sync-helpers.sh scripts/test/fixtures/
git commit -m "feat(sync): dump_looks_like_sql sanity check + fixtures"
```

---

### Task 4: `build_truncate_stmt` helper (TDD)

**Files:**
- Modify: `scripts/sync-prod-to-dev.sh`
- Modify: `scripts/test/test-sync-helpers.sh`

- [ ] **Step 1: Write the failing test**

Add to `scripts/test/test-sync-helpers.sh` before the summary:

```bash
# --- build_truncate_stmt ---
check "truncate stmt" "$(build_truncate_stmt 'public.a, public.b')" \
  "TRUNCATE public.a, public.b, auth.users RESTART IDENTITY CASCADE;"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/test/test-sync-helpers.sh`
Expected: `NOT OK - truncate stmt` (empty output), `failed: 1`, exit 1.

- [ ] **Step 3: Implement `build_truncate_stmt`**

Add to `scripts/sync-prod-to-dev.sh` after `dump_looks_like_sql`:

```bash
build_truncate_stmt() {
  # $1 = comma-separated list of fully-qualified public tables
  # → one TRUNCATE covering all public tables + auth.users (CASCADE clears auth internals).
  printf 'TRUNCATE %s, auth.users RESTART IDENTITY CASCADE;' "$1"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/test/test-sync-helpers.sh`
Expected: `ok   - truncate stmt`, `failed: 0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-prod-to-dev.sh scripts/test/test-sync-helpers.sh
git commit -m "feat(sync): build_truncate_stmt helper"
```

---

## Chunk 2: Integration phases, main, and docs

> Integration functions touch a live prod server + the dev Docker stack, so they are verified by a `--dry-run` preview and the end-to-end acceptance run (Task 11), not by unit tests. Each task states its exact verification command and expected output.

### Task 5: `preflight` (tool check, env, dev guard, migrate, confirm)

**Files:**
- Modify: `scripts/sync-prod-to-dev.sh` (add `preflight` after the pure helpers)

- [ ] **Step 1: Implement `preflight`**

Add to `scripts/sync-prod-to-dev.sh` after `build_truncate_stmt`:

```bash
preflight() {
  local tool ans=""
  for tool in docker rsync ssh curl supabase; do
    command -v "$tool" >/dev/null 2>&1 \
      || { echo "ERROR: required tool not found on PATH: $tool" >&2; exit 1; }
  done

  [[ -f "$ENV_FILE" ]] || {
    echo "ERROR: config not found: $ENV_FILE" >&2
    echo "       Copy scripts/sync-prod-to-dev.env.example and fill it in." >&2
    exit 1; }
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  : "${PROD_SSH:?set PROD_SSH in $ENV_FILE}"
  : "${PROD_DIR:?set PROD_DIR in $ENV_FILE}"
  : "${PROD_STORAGE_DIR:?set PROD_STORAGE_DIR in $ENV_FILE}"
  : "${DEV_SUPABASE_URL:?set DEV_SUPABASE_URL in $ENV_FILE}"

  # Dev guard: target is resolved purely from local config.toml → local container only.
  DEV_DB_CONTAINER="$(dev_db_container "$CONFIG_TOML")"
  docker ps --format '{{.Names}}' | grep -qx "$DEV_DB_CONTAINER" || {
    echo "ERROR: dev DB container '$DEV_DB_CONTAINER' is not running." >&2
    echo "       Start the local stack first: (cd Docker && supabase start)" >&2
    exit 1; }
  docker exec "$DEV_DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 || {
    echo "ERROR: dev DB not accepting connections in $DEV_DB_CONTAINER" >&2; exit 1; }

  echo "==> Applying any pending migrations to the dev DB (non-destructive)..."
  ( cd "$SUPABASE_PROJECT_DIR" && supabase migration up ) || {
    echo "ERROR: 'supabase migration up' failed" >&2; exit 1; }

  if ! $ASSUME_YES && ! $DRY_RUN; then
    echo ""
    echo "This will REPLACE ALL DATA in your local dev DB"
    echo "  container : $DEV_DB_CONTAINER"
    echo "  source    : $PROD_SSH (read-only)"
    printf "Continue? [y/N] "
    read -r ans
    [[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  fi
}
```

- [ ] **Step 2: Temporarily wire `main` to call only `preflight` for verification**

Replace the placeholder `main` body with:

```bash
main() {
  mkdir -p "$WORKDIR"
  preflight
  echo "preflight OK (container=$DEV_DB_CONTAINER)"
}
```

(The full `main` is written in Task 9; this stub just lets us verify `preflight`.)

- [ ] **Step 3: Verify the tool check + missing-env path**

Run (with no env file present): `bash scripts/sync-prod-to-dev.sh`
Expected: `ERROR: config not found: …/scripts/sync-prod-to-dev.env` and exit 1.

- [ ] **Step 4: Verify the dev guard with the real local stack**

Ensure `supabase start` is running, create a throwaway env file:

```bash
cat > scripts/sync-prod-to-dev.env <<'EOF'
PROD_SSH="placeholder@localhost"
PROD_DIR="/tmp"
PROD_STORAGE_DIR="/tmp"
DEV_SUPABASE_URL="http://127.0.0.1:54321"
EOF
bash scripts/sync-prod-to-dev.sh --yes
```
Expected: prints the "Applying any pending migrations" line, then `preflight OK (container=supabase_db_mdb-esp32-cashless)`. If the stack is NOT running, expected: `ERROR: dev DB container 'supabase_db_mdb-esp32-cashless' is not running.`

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-prod-to-dev.sh
git commit -m "feat(sync): preflight with tool check, local-only dev guard, migrate, confirm"
```

---

### Task 6: `dump_prod` and `fetch_images`

**Files:**
- Modify: `scripts/sync-prod-to-dev.sh`

- [ ] **Step 1: Implement `dump_prod`**

Add after `preflight`:

```bash
dump_prod() {
  if $DRY_RUN; then
    echo "[dry-run] would dump public + auth.{users,identities} (data-only) from $PROD_SSH"
    return 0
  fi
  echo "==> Dumping public schema from prod (data-only)..."
  ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db \
    pg_dump -U postgres -d postgres --data-only --no-owner --no-privileges \
    --schema=public 2>/dev/null" > "$WORKDIR/public.sql"
  dump_looks_like_sql "$WORKDIR/public.sql" || {
    echo "ERROR: public dump does not look like SQL (SSH/compose error?)" >&2; exit 1; }

  echo "==> Dumping auth.users + auth.identities from prod (data-only)..."
  ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db \
    pg_dump -U postgres -d postgres --data-only --no-owner --no-privileges \
    --table=auth.users --table=auth.identities 2>/dev/null" > "$WORKDIR/auth.sql"
  dump_looks_like_sql "$WORKDIR/auth.sql" || {
    echo "ERROR: auth dump does not look like SQL (SSH/compose error?)" >&2; exit 1; }
}
```

- [ ] **Step 2: Implement `fetch_images`**

Add after `dump_prod`:

```bash
fetch_images() {
  local img_dir
  if $DRY_RUN; then
    echo "[dry-run] would find product-images under $PROD_STORAGE_DIR and rsync it to $WORKDIR/product-images/"
    return 0
  fi
  echo "==> Locating product-images on prod..."
  img_dir="$(ssh "$PROD_SSH" "find '$PROD_STORAGE_DIR' -type d -name product-images | head -n1")"
  if [[ -z "$img_dir" ]]; then
    echo "WARN: no 'product-images' directory found under $PROD_STORAGE_DIR; skipping images." >&2
    return 0
  fi
  echo "==> Syncing images from $img_dir ..."
  mkdir -p "$WORKDIR/product-images"
  rsync -a -e ssh "$PROD_SSH:$img_dir/" "$WORKDIR/product-images/"
}
```

- [ ] **Step 3: Verify via dry-run**

Temporarily extend the `main` stub to call them, or call directly after sourcing. Simplest: run with `--dry-run` once Task 9's `main` exists. For now verify by sourcing:

Run:
```bash
bash -c 'source scripts/sync-prod-to-dev.sh; DRY_RUN=true; PROD_SSH=x PROD_STORAGE_DIR=/srv WORKDIR=/tmp/sync dump_prod; fetch_images'
```
Expected: two `[dry-run] would …` lines, exit 0, no SSH attempted.

- [ ] **Step 4: Commit**

```bash
git add scripts/sync-prod-to-dev.sh
git commit -m "feat(sync): dump_prod (data-only over SSH) + fetch_images (rsync)"
```

---

### Task 7: `restore_db` (atomic data-only load)

**Files:**
- Modify: `scripts/sync-prod-to-dev.sh`

- [ ] **Step 1: Implement `restore_db`**

Add after `fetch_images`:

```bash
restore_db() {
  local public_tables truncate_stmt
  public_tables="$(docker exec "$DEV_DB_CONTAINER" psql -tA -U postgres -d postgres -c \
    "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname='public'")"
  [[ -n "$public_tables" ]] || { echo "ERROR: could not list public tables in dev" >&2; exit 1; }
  truncate_stmt="$(build_truncate_stmt "$public_tables")"

  if $DRY_RUN; then
    echo "[dry-run] would restore into $DEV_DB_CONTAINER inside one transaction:"
    echo "  BEGIN; SET session_replication_role = replica;"
    echo "  $truncate_stmt"
    echo "  \\i auth.sql ; \\i public.sql"
    echo "  SET session_replication_role = default; COMMIT;"
    return 0
  fi

  echo "==> Restoring into dev (single transaction, triggers/FK off)..."
  {
    echo "BEGIN;"
    echo "SET session_replication_role = replica;"
    echo "$truncate_stmt"
    cat "$WORKDIR/auth.sql"
    cat "$WORKDIR/public.sql"
    echo "SET session_replication_role = default;"
    echo "COMMIT;"
  } | docker exec -i "$DEV_DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -d postgres
}
```

- [ ] **Step 2: Verify the truncate-list query against the real dev DB**

Run (dev stack up):
```bash
docker exec supabase_db_mdb-esp32-cashless psql -tA -U postgres -d postgres -c \
  "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname='public'" | tr ',' '\n' | head
```
Expected: a comma-separated list including `public.companies`, `public.embeddeds`, `public.sales`, etc. (confirms the query and quoting work through `docker exec`).

- [ ] **Step 3: Verify the dry-run assembly**

Run:
```bash
bash -c 'source scripts/sync-prod-to-dev.sh; DRY_RUN=true; DEV_DB_CONTAINER=supabase_db_mdb-esp32-cashless restore_db'
```
Expected: prints the `BEGIN; … TRUNCATE public.…, auth.users RESTART IDENTITY CASCADE; … COMMIT;` preview using the *real* table list, executes nothing.

- [ ] **Step 4: Commit**

```bash
git add scripts/sync-prod-to-dev.sh
git commit -m "feat(sync): restore_db atomic data-only load via docker exec psql"
```

---

### Task 8: `upload_images` (re-ingest through dev Storage API)

**Files:**
- Modify: `scripts/sync-prod-to-dev.sh`

- [ ] **Step 1: Implement `upload_images`**

Add after `restore_db`:

```bash
upload_images() {
  local key namedir obj file mime code total=0 fails=0
  if $DRY_RUN; then
    echo "[dry-run] would upload each product-images object via POST $DEV_SUPABASE_URL/storage/v1/object/product-images/<name>"
    return 0
  fi
  [[ -d "$WORKDIR/product-images" ]] || { echo "No images to upload."; return 0; }

  key="$( ( cd "$SUPABASE_PROJECT_DIR" && supabase status -o env ) \
          | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' )"
  [[ -n "$key" ]] || { echo "ERROR: could not read SERVICE_ROLE_KEY from 'supabase status'" >&2; exit 1; }

  echo "==> Uploading product images to dev Storage API..."
  # process substitution (not a pipe) so the counters persist in this shell
  while IFS= read -r namedir; do
    obj="$(basename "$namedir")"
    file="$(ls -t "$namedir" 2>/dev/null | head -n1)"
    [[ -n "$file" ]] || continue
    file="$namedir/$file"
    mime="$(mime_for "$obj")"
    total=$((total+1))
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      "$DEV_SUPABASE_URL/storage/v1/object/product-images/$obj" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: $mime" \
      -H "x-upsert: true" \
      --data-binary "@$file" || echo 000)"
    if [[ ! "$code" =~ ^2 ]]; then
      echo "WARN: upload failed (HTTP $code) for $obj" >&2
      fails=$((fails+1))
    fi
  done < <(find "$WORKDIR/product-images" -mindepth 1 -maxdepth 1 -type d)

  echo "Images uploaded: $((total - fails))/$total ($fails failed)."
}
```

- [ ] **Step 2: Verify dry-run + the service-key parse**

Run:
```bash
bash -c 'source scripts/sync-prod-to-dev.sh; DRY_RUN=true upload_images'
( cd Docker && supabase status -o env | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' )
```
Expected: the dry-run line, then a non-empty JWT string from the second command (confirms the parse).

- [ ] **Step 3: Commit**

```bash
git add scripts/sync-prod-to-dev.sh
git commit -m "feat(sync): upload_images re-ingests product-images via Storage API"
```

---

### Task 9: `verify_and_cleanup`, full `main`, arg parsing, usage

**Files:**
- Modify: `scripts/sync-prod-to-dev.sh`

- [ ] **Step 1: Implement `verify_and_cleanup`**

Add after `upload_images`:

```bash
verify_and_cleanup() {
  echo "==> Row counts in dev:"
  docker exec "$DEV_DB_CONTAINER" psql -U postgres -d postgres -c "
    SELECT 'auth.users'            AS entity, count(*) FROM auth.users
    UNION ALL SELECT 'companies',      count(*) FROM public.companies
    UNION ALL SELECT 'embeddeds',      count(*) FROM public.embeddeds
    UNION ALL SELECT 'vendingMachine', count(*) FROM public.\"vendingMachine\"
    UNION ALL SELECT 'products',       count(*) FROM public.products
    UNION ALL SELECT 'sales',          count(*) FROM public.sales
    UNION ALL SELECT 'storage(images)',count(*) FROM storage.objects WHERE bucket_id='product-images';"

  if [[ -d "$WORKDIR/product-images" ]]; then
    local local_imgs
    local_imgs="$(find "$WORKDIR/product-images" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    echo "Local image objects fetched: $local_imgs (storage(images) below this = uploads skipped for size/mime)."
  fi

  if ! $KEEP_DUMPS; then rm -f "$WORKDIR/public.sql" "$WORKDIR/auth.sql"; fi
  if $CLEAN_CACHE; then rm -rf "$WORKDIR/product-images"; fi
}
```

- [ ] **Step 2: Implement `usage` and the full `main` (replace the stub)**

Replace the Task-5 `main` stub with:

```bash
usage() {
  cat <<'EOF'
Usage: scripts/sync-prod-to-dev.sh [options]

Refreshes the local Supabase CLI dev DB with production data
(clones prod auth.users/identities + all public data + product images).

Options:
  --yes          Skip the confirmation prompt (for unattended/cron runs)
  --dry-run      Print what would happen; touch nothing
  --skip-images  Refresh the DB only (no image fetch/upload)
  --keep-dumps   Keep tmp/sync/*.sql after the run
  --clean        Also delete the tmp/sync/product-images cache after the run
  -h, --help     Show this help

Config: scripts/sync-prod-to-dev.env (copy from .env.example). Requires a
running local stack (cd Docker && supabase start).
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)         ASSUME_YES=true ;;
      --dry-run)     DRY_RUN=true ;;
      --skip-images) SKIP_IMAGES=true ;;
      --keep-dumps)  KEEP_DUMPS=true ;;
      --clean)       CLEAN_CACHE=true ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
  done

  mkdir -p "$WORKDIR"
  preflight
  dump_prod
  $SKIP_IMAGES || fetch_images
  restore_db
  $SKIP_IMAGES || upload_images
  verify_and_cleanup
  echo ""
  echo "Done. Log into dev (http://localhost:3000) with your PRODUCTION credentials."
}
```

- [ ] **Step 3: Re-run the unit tests (ensure nothing regressed when sourcing the larger script)**

Run: `bash scripts/test/test-sync-helpers.sh`
Expected: all `ok`, `failed: 0`, exit 0.

- [ ] **Step 4: Verify `--help` and full `--dry-run`**

Run:
```bash
bash scripts/sync-prod-to-dev.sh --help
bash scripts/sync-prod-to-dev.sh --dry-run --yes
```
Expected for `--dry-run`: preflight runs for real (tool check, container guard, `supabase migration up`), then `[dry-run] would …` lines for dump/images/restore/upload, then the dev row counts (read-only), then the "Done" line. No prod SSH, no truncate.

(Requires the throwaway env file from Task 5 Step 4 and a running stack.)

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-prod-to-dev.sh
git commit -m "feat(sync): verify_and_cleanup + full main, arg parsing, usage"
```

---

### Task 10: `env.example` and README

**Files:**
- Create: `scripts/sync-prod-to-dev.env.example`
- Create: `scripts/README.md`

- [ ] **Step 1: Create the env template**

`scripts/sync-prod-to-dev.env.example`:

```sh
# Copy to scripts/sync-prod-to-dev.env and fill in. The real file is gitignored.
# This file is sourced by bash, so use shell-quoting.

# SSH target for the production server (user@host or a ~/.ssh/config alias).
PROD_SSH="user@your-prod-host"

# Absolute path on the server to the dir that contains docker-compose.yml.
PROD_DIR="/home/user/mdb-esp32-cashless/Docker"

# Storage root on the server (the 'product-images' dir lives somewhere under it).
PROD_STORAGE_DIR="/home/user/mdb-esp32-cashless/Docker/volumes/storage"

# Local Supabase Storage API base URL (the CLI default).
DEV_SUPABASE_URL="http://127.0.0.1:54321"
```

- [ ] **Step 2: Create the README**

`scripts/README.md`:

````markdown
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
````

- [ ] **Step 3: Make the script executable**

Run: `chmod +x scripts/sync-prod-to-dev.sh`

- [ ] **Step 4: Commit**

```bash
git add scripts/sync-prod-to-dev.env.example scripts/README.md scripts/sync-prod-to-dev.sh
git commit -m "docs(sync): env template + README with usage, safety, scheduling"
```

---

### Task 11: End-to-end acceptance run (manual integration test)

**Files:** none (verification only)

This is the real integration test — it requires a filled-in `scripts/sync-prod-to-dev.env` and SSH access to prod.

- [ ] **Step 1: Dry-run end to end**

Run: `./scripts/sync-prod-to-dev.sh --dry-run`
Expected: preflight passes; `[dry-run]` previews for all phases; real dev row counts; no changes.

- [ ] **Step 2: Real run**

Run: `./scripts/sync-prod-to-dev.sh` and confirm at the prompt.
Expected: dumps download, restore completes with no error, images upload (`N/N`), final counts are non-zero and match prod magnitudes.

- [ ] **Step 3: Acceptance checks (from the spec)**

- [ ] Log into http://localhost:3000 with a **production** email + password → succeeds, shows that user's real company data.
- [ ] A product that has an image in prod shows its image in dev (network 200, not 404).
- [ ] Re-run the script → idempotent (no duplicate rows; images upsert).
- [ ] Stop the stack (`supabase stop`), run the script → refuses with the "container not running" error before touching anything.
- [ ] Re-run `bash scripts/test/test-sync-helpers.sh` → all green.

- [ ] **Step 4: (Optional) commit a short run log**

If desired, note the observed counts in the commit message of a follow-up, or leave untracked. No code commit required for this task.

---

## Done criteria

- `bash scripts/test/test-sync-helpers.sh` passes (pure helpers).
- `./scripts/sync-prod-to-dev.sh --dry-run` previews all phases with no side effects.
- A real run replaces dev data, prod login works in dev, product images render.
- The script refuses to run unless the local dev container is up.
