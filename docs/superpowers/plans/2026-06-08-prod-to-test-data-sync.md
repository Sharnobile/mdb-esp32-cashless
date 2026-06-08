# Prod → Test Data Sync Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `scripts/sync-prod-to-test.sh` — a script run *on the test box* that refreshes the test server's DB + product images with production data, with a layered guard so it can never run against prod.

**Architecture:** A single bash orchestrator mirroring the proven `scripts/sync-prod-to-dev.sh`, re-pointed from a local Supabase CLI container to the test box's own Docker compose stack. Pure decision logic (env parsing, the domain/migration guards, the truncate statement) is extracted into unit-tested helper functions; the I/O phases (SSH `pg_dump`/`rsync` from prod, local `docker compose exec` restore, Storage-API image upload) are thin wrappers verified by `shellcheck` + a real `--dry-run` on the test box.

**Tech Stack:** Bash 3.2+ (portable), `docker compose`, `ssh`, `rsync`, `curl`, Postgres `pg_dump`/`psql` (run inside containers), Supabase Storage REST API.

**Spec:** `docs/superpowers/specs/2026-06-08-prod-to-test-data-sync-design.md`

**Reference implementation (read before starting):** `scripts/sync-prod-to-dev.sh` (the sibling this is modelled on) and its tests `scripts/test/test-sync-helpers.sh` + `scripts/test/fixtures/`.

**Key invariants (do not violate):**
- The destructive restore target is ALWAYS the local compose `db` service in `<repo>/Docker` — the script never accepts a remote DB address for writes. Prod is read-only (`pg_dump` + `rsync` + reading `$PROD_DIR/.env`).
- Parse the test box's `Docker/.env` with `grep | cut -d= -f2-`, **never** `source` (it ships unquoted values with spaces + multi-line PEM keys). Follow the pattern already in `Docker/update.sh:251`.
- The `TRUNCATE` uses **no** `RESTART IDENTITY` (the proven dev *script* omits it deliberately; ignore the dev *spec* text that shows it). `CASCADE` would try to reset auth-owned sequences the non-superuser `postgres` role cannot; public sequences are restored by the dump's `setval()`.

---

## Chunk 1: Scaffolding & unit-tested pure helpers

This chunk produces a syntactically-valid, shellcheck-clean script skeleton with all pure decision logic implemented and unit-tested. No prod/test infrastructure is needed to complete or verify it.

### Task 1: Script skeleton + config template + gitignore

**Files:**
- Create: `scripts/sync-prod-to-test.sh`
- Create: `scripts/sync-prod-to-test.env.example`
- Modify: `.gitignore` (after the existing dev-sync entries, lines 41–43)

- [ ] **Step 1: Add gitignore entries**

Modify `.gitignore` — after the existing block:
```
# Prod→dev data sync (scripts/sync-prod-to-dev.sh)
tmp/sync/
scripts/sync-prod-to-dev.env
```
append:
```
# Prod→test data sync (scripts/sync-prod-to-test.sh)
tmp/sync-test/
scripts/sync-prod-to-test.env
```

- [ ] **Step 2: Write the config template**

Create `scripts/sync-prod-to-test.env.example`:
```sh
# Copy to scripts/sync-prod-to-test.env and fill in. The real file is gitignored.
# This file is sourced by bash, so use shell-quoting.
#
# Run this script ON THE TEST BOX. It pulls from prod read-only over SSH and
# does all destructive work locally against this box's own Docker/ stack.

# SSH target for the PRODUCTION server (user@host or a ~/.ssh/config alias).
# This box must have an (ideally read-only) SSH key authorised on prod.
PROD_SSH="user@your-prod-host"

# Absolute path on the PROD server to the dir that contains docker-compose.yml.
PROD_DIR="/home/user/mdb-esp32-cashless/Docker"

# Storage root on the PROD server (the 'product-images' dir lives under it).
PROD_STORAGE_DIR="/home/user/mdb-esp32-cashless/Docker/volumes/storage"

# Safety guard A: this substring MUST appear in THIS box's Docker/.env
# SUPABASE_PUBLIC_URL. If it doesn't, the script refuses to run (it may be the
# prod box). Set it to your test server's domain, e.g. "test.vmflow.example".
TEST_EXPECTED_DOMAIN="test.your-domain.example"
```

- [ ] **Step 3: Write the script skeleton (header, vars, flags, usage, main with stubs)**

Create `scripts/sync-prod-to-test.sh`:
```bash
#!/usr/bin/env bash
# sync-prod-to-test.sh — refresh the TEST server's DB + product images with production data.
# Runs ON the test box. Pulls prod read-only over SSH; all destructive work is LOCAL.
# Design: docs/superpowers/specs/2026-06-08-prod-to-test-data-sync-design.md
# Portable to macOS/Linux bash 3.2 — no bash-4-only features.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$REPO_ROOT/Docker"                 # this box's compose dir (restore target)
TEST_ENV="$TEST_DIR/.env"                    # the full Supabase env file on this box
ENV_FILE="$SCRIPT_DIR/sync-prod-to-test.env" # operator config (PROD_SSH, expected domain)
WORKDIR="$REPO_ROOT/tmp/sync-test"

# Flag defaults
ASSUME_YES=false
CLEAN_CACHE=false
KEEP_DUMPS=false
SKIP_IMAGES=false
DRY_RUN=false

# Resolved in preflight()
TEST_PUBLIC_URL=""
TEST_SERVICE_KEY=""
TEST_SUPABASE_URL=""
PROD_PUBLIC_URL=""

# ---------- pure helpers (unit-tested in scripts/test/test-sync-test-helpers.sh) ----------
# (added in Tasks 2–4)

# ---------- integration phases (verified via --dry-run, not unit-tested) ----------
# (added in Chunk 2)
preflight()           { echo "TODO preflight"; }
dump_prod()           { echo "TODO dump_prod"; }
fetch_images()        { echo "TODO fetch_images"; }
restore_db()          { echo "TODO restore_db"; }
upload_images()       { echo "TODO upload_images"; }
verify_and_cleanup()  { echo "TODO verify_and_cleanup"; }

# ---------- entry point ----------

usage() {
  cat <<'EOF'
Usage: scripts/sync-prod-to-test.sh [options]

Refreshes the TEST server's database + product images with PRODUCTION data.
Run this ON THE TEST BOX. Prod is read-only; all destructive work is local.

Options:
  --yes          Skip the confirmation prompt (for unattended/cron runs)
  --dry-run      Run the read-only safety guards and print planned actions; makes no writes
  --skip-images  Refresh the DB only (no image fetch/upload)
  --keep-dumps   Keep tmp/sync-test/*.sql after the run
  --clean        Also delete the tmp/sync-test/product-images cache after the run
  -h, --help     Show this help

Config: scripts/sync-prod-to-test.env (copy from .env.example).
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
  echo "Done. Log into the test frontend ($TEST_PUBLIC_URL) with your production credentials."
}

# Only run main when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x scripts/sync-prod-to-test.sh`

- [ ] **Step 5: Verify syntax, lint, and help**

Run: `bash -n scripts/sync-prod-to-test.sh && shellcheck scripts/sync-prod-to-test.sh && bash scripts/sync-prod-to-test.sh --help`
Expected: no syntax errors; shellcheck clean (or only the documented SC1090/SC1091 source warnings — none yet in this task); `--help` prints the usage block and exits 0.
(If `shellcheck` is not installed, note it and rely on `bash -n`; do not fail the task.)

- [ ] **Step 6: Commit**

```bash
git add scripts/sync-prod-to-test.sh scripts/sync-prod-to-test.env.example .gitignore
git commit -m "feat(scripts): scaffold sync-prod-to-test.sh (skeleton, config template, gitignore)"
```

---

### Task 2: Copy the three proven pure helpers + create the test harness

These three helpers are byte-identical to `sync-prod-to-dev.sh` (intentionally copied — each `sync-*.sh` is self-contained). The new test file sources ONLY this script, so there is no redefinition collision with the existing `test-sync-helpers.sh`.

**Files:**
- Modify: `scripts/sync-prod-to-test.sh` (fill the "pure helpers" section)
- Create: `scripts/test/test-sync-test-helpers.sh`
- Reuse (no change): `scripts/test/fixtures/{good-dump.sql,bad-dump.txt,empty.sql,set-first-dump.sql,select-first-dump.sql,backslash-dump.sql}`

- [ ] **Step 1: Write the failing test harness**

Create `scripts/test/test-sync-test-helpers.sh`:
```bash
#!/usr/bin/env bash
# Unit tests for the pure helpers in sync-prod-to-test.sh.
# Run: bash scripts/test/test-sync-test-helpers.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../sync-prod-to-test.sh"   # sourced → main() is NOT executed
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

# --- dump_looks_like_sql (fixtures reused from the dev test suite) ---
dump_looks_like_sql "$HERE/fixtures/good-dump.sql";        check_rc "good dump accepted"           "$?" "0"
dump_looks_like_sql "$HERE/fixtures/bad-dump.txt";         check_rc "bad dump rejected"            "$?" "1"
dump_looks_like_sql "$HERE/fixtures/empty.sql";            check_rc "empty dump rejected"          "$?" "1"
dump_looks_like_sql "$HERE/fixtures/set-first-dump.sql";   check_rc "SET-first dump accepted"      "$?" "0"
dump_looks_like_sql "$HERE/fixtures/select-first-dump.sql";check_rc "SELECT-first dump accepted"   "$?" "0"
dump_looks_like_sql "$HERE/fixtures/backslash-dump.sql";   check_rc "backslash-first dump accepted" "$?" "0"

# --- build_truncate_stmt ---
check "truncate stmt" "$(build_truncate_stmt 'public.a, public.b')" \
  "TRUNCATE public.a, public.b, auth.users CASCADE;"

echo "----"
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/test/test-sync-test-helpers.sh`
Expected: FAIL — the helpers don't exist yet, so `mime_for`/`dump_looks_like_sql`/`build_truncate_stmt` print "command not found" and assertions report `NOT OK`; final line non-zero exit.

- [ ] **Step 3: Implement the three helpers**

In `scripts/sync-prod-to-test.sh`, replace the `# (added in Tasks 2–4)` line with:
```bash
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

dump_looks_like_sql() {
  # $1 = path to a dump file. Returns 0 if it looks like pg_dump SQL output.
  local f="$1" line
  [[ -s "$f" ]] || return 1
  line="$(grep -m1 -vE '^[[:space:]]*$' "$f" 2>/dev/null || true)"
  [[ "$line" =~ ^(SET|SELECT|--|\\) ]]
}

build_truncate_stmt() {
  # $1 = comma-separated list of fully-qualified public tables
  # → one TRUNCATE covering all public tables + auth.users (CASCADE clears auth internals).
  # No RESTART IDENTITY: CASCADE reaches auth-owned sequences the non-superuser `postgres`
  # role cannot reset; public sequence values are restored by the dump's setval() calls.
  printf 'TRUNCATE %s, auth.users CASCADE;' "$1"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/test/test-sync-test-helpers.sh`
Expected: PASS — all `ok`, final line `passed: 13, failed: 0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-prod-to-test.sh scripts/test/test-sync-test-helpers.sh
git commit -m "feat(scripts): pure helpers (mime/dump-check/truncate) + test harness for sync-prod-to-test"
```

---

### Task 3: `read_env_value` helper (the `.env` parsing contract) + fixture

**Files:**
- Modify: `scripts/sync-prod-to-test.sh` (add helper)
- Modify: `scripts/test/test-sync-test-helpers.sh` (add tests)
- Create: `scripts/test/fixtures/sample.env`

- [ ] **Step 1: Create the fixture**

Create `scripts/test/fixtures/sample.env` (deliberately exercises the hard cases: unquoted value with spaces, double-quoted JWT with `==` padding, single-quoted value):
```
SUPABASE_PUBLIC_URL=https://test.vmflow.example
SERVICE_ROLE_KEY="eyJhbGciOiJIUzI1NiJ.padding=="
KONG_HTTP_PORT=8000
STUDIO_DEFAULT_ORGANIZATION=Default Organization
QUOTED_SINGLE='hello world'
```

- [ ] **Step 2: Write the failing tests**

In `scripts/test/test-sync-test-helpers.sh`, before the final `echo "----"` block, add:
```bash
# --- read_env_value ---
check "env: plain url"        "$(read_env_value "$HERE/fixtures/sample.env" SUPABASE_PUBLIC_URL)" "https://test.vmflow.example"
check "env: quoted jwt + =="  "$(read_env_value "$HERE/fixtures/sample.env" SERVICE_ROLE_KEY)"    "eyJhbGciOiJIUzI1NiJ.padding=="
check "env: value with space" "$(read_env_value "$HERE/fixtures/sample.env" STUDIO_DEFAULT_ORGANIZATION)" "Default Organization"
check "env: single-quoted"    "$(read_env_value "$HERE/fixtures/sample.env" QUOTED_SINGLE)"       "hello world"
read_env_value "$HERE/fixtures/sample.env" NOT_PRESENT; check_rc "env: missing key rc=1" "$?" "1"
read_env_value "$HERE/fixtures/does-not-exist.env" SUPABASE_PUBLIC_URL; check_rc "env: missing file rc=1" "$?" "1"
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash scripts/test/test-sync-test-helpers.sh`
Expected: FAIL — `read_env_value: command not found`, new assertions `NOT OK`.

- [ ] **Step 4: Implement `read_env_value`**

In `scripts/sync-prod-to-test.sh`, after `build_truncate_stmt`, add:
```bash
read_env_value() {
  # $1 = path to a .env file, $2 = key. Echoes the value (surrounding quotes +
  # trailing CR stripped). Returns 1 if the file or key is absent / value empty.
  # Uses grep|cut, NEVER `source`: the full Supabase .env ships unquoted values
  # with spaces (STUDIO_DEFAULT_ORGANIZATION=Default Organization) and multi-line
  # PEM blocks (APNS_PRIVATE_KEY) that `source` mis-parses. cut -f2- keeps any
  # '=' in the value (e.g. a JWT's trailing '==' padding). See Docker/update.sh.
  local file="$1" key="$2" val
  [[ -f "$file" ]] || return 1
  val="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2-)"
  [[ -n "$val" ]] || return 1
  val="${val%$'\r'}"                  # strip trailing CR (CRLF files)
  val="${val#\"}"; val="${val%\"}"    # strip surrounding double quotes
  val="${val#\'}"; val="${val%\'}"    # strip surrounding single quotes
  printf '%s' "$val"
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash scripts/test/test-sync-test-helpers.sh`
Expected: PASS — `passed: 19, failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/sync-prod-to-test.sh scripts/test/test-sync-test-helpers.sh scripts/test/fixtures/sample.env
git commit -m "feat(scripts): read_env_value — robust .env parse (grep|cut, not source) + tests"
```

---

### Task 4: Guard-decision helpers `domain_in_url` + `migrations_match`

**Files:**
- Modify: `scripts/sync-prod-to-test.sh` (add helpers)
- Modify: `scripts/test/test-sync-test-helpers.sh` (add tests)

- [ ] **Step 1: Write the failing tests**

In `scripts/test/test-sync-test-helpers.sh`, before the final `echo "----"` block, add:
```bash
# --- domain_in_url (Guard A decision) ---
domain_in_url "https://test.vmflow.example" "test.vmflow.example"; check_rc "domain match"       "$?" "0"
domain_in_url "https://prod.vmflow.example" "test.vmflow.example"; check_rc "domain mismatch"    "$?" "1"
domain_in_url "https://test.vmflow.example" "";                    check_rc "empty domain rc=1"  "$?" "1"

# --- migrations_match (Guard C decision): args = prod_max prod_count test_max test_count ---
migrations_match "20260608_x" "100" "20260608_x" "100"; check_rc "migrations equal"        "$?" "0"
migrations_match "20260608_x" "100" "20260608_x" "99";  check_rc "migrations count differs" "$?" "1"
migrations_match "20260608_x" "100" "20260607_y" "100"; check_rc "migrations max differs"   "$?" "1"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/test/test-sync-test-helpers.sh`
Expected: FAIL — `domain_in_url`/`migrations_match` not found.

- [ ] **Step 3: Implement the two helpers**

In `scripts/sync-prod-to-test.sh`, after `read_env_value`, add:
```bash
domain_in_url() {
  # $1 = url, $2 = expected domain substring. rc 0 if present, 1 otherwise.
  # Guard A's decision: the test box's SUPABASE_PUBLIC_URL must contain the
  # operator-configured test domain. Substring containment is by design.
  local url="$1" domain="$2"
  [[ -n "$domain" ]] || return 1
  [[ "$url" == *"$domain"* ]]
}

migrations_match() {
  # $1=prod_max $2=prod_count $3=test_max $4=test_count → rc 0 only if BOTH the
  # latest-applied migration filename and the applied count match. Guard C's
  # decision: detects the common version-drift case before any write. (True
  # schema skew that slips past is still caught by the atomic restore rollback.)
  [[ "$1" == "$3" && "$2" == "$4" ]]
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash scripts/test/test-sync-test-helpers.sh`
Expected: PASS — `passed: 25, failed: 0`.

- [ ] **Step 5: shellcheck the script**

Run: `shellcheck scripts/sync-prod-to-test.sh`
Expected: clean (no errors). The `source "$ENV_FILE"` in Chunk 2 will need an inline `# shellcheck disable=SC1090`; not present yet.
(If `shellcheck` is not installed, skip it and rely on `bash -n`; do not fail the task.)

- [ ] **Step 6: Commit**

```bash
git add scripts/sync-prod-to-test.sh scripts/test/test-sync-test-helpers.sh
git commit -m "feat(scripts): guard-decision helpers domain_in_url + migrations_match (+ tests)"
```

---

## Chunk 2: Integration phases & wiring

This chunk fills the phase stubs with real I/O. These cannot be unit-tested without a real prod host + running test stack, so each task is verified by `bash -n` + `shellcheck` + the still-passing helper unit tests, and the whole script is exercised by a real `--dry-run` in the final acceptance task (run by the user on the test box).

### Task 5: `preflight()` — load config, read local identity, run guards A/B/C, confirm

**Files:**
- Modify: `scripts/sync-prod-to-test.sh` (replace the `preflight()` stub)

- [ ] **Step 1: Replace the `preflight()` stub**

```bash
preflight() {
  local tool ans=""
  for tool in docker ssh rsync curl; do
    command -v "$tool" >/dev/null 2>&1 \
      || { echo "ERROR: required tool not found on PATH: $tool" >&2; exit 1; }
  done

  [[ -f "$ENV_FILE" ]] || {
    echo "ERROR: config not found: $ENV_FILE" >&2
    echo "       Copy scripts/sync-prod-to-test.env.example and fill it in." >&2
    exit 1; }
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  : "${PROD_SSH:?set PROD_SSH in $ENV_FILE}"
  : "${PROD_DIR:?set PROD_DIR in $ENV_FILE}"
  : "${PROD_STORAGE_DIR:?set PROD_STORAGE_DIR in $ENV_FILE}"
  : "${TEST_EXPECTED_DOMAIN:?set TEST_EXPECTED_DOMAIN in $ENV_FILE}"

  [[ -f "$TEST_ENV" ]] || { echo "ERROR: test stack env not found: $TEST_ENV" >&2; exit 1; }
  [[ -f "$TEST_DIR/docker-compose.yml" ]] || { echo "ERROR: $TEST_DIR is not a compose dir (no docker-compose.yml)" >&2; exit 1; }

  # Read this box's identity from its own Docker/.env (grep|cut, never source).
  TEST_PUBLIC_URL="$(read_env_value "$TEST_ENV" SUPABASE_PUBLIC_URL || true)"
  TEST_SERVICE_KEY="$(read_env_value "$TEST_ENV" SERVICE_ROLE_KEY || true)"
  local kong_port; kong_port="$(read_env_value "$TEST_ENV" KONG_HTTP_PORT || true)"
  [[ -n "$kong_port" ]] || kong_port=8000
  TEST_SUPABASE_URL="http://localhost:${kong_port}"
  [[ -n "$TEST_PUBLIC_URL" ]]  || { echo "ERROR: SUPABASE_PUBLIC_URL missing from $TEST_ENV" >&2; exit 1; }
  [[ -n "$TEST_SERVICE_KEY" ]] || { echo "ERROR: SERVICE_ROLE_KEY missing from $TEST_ENV" >&2; exit 1; }

  # --- Guard A: this box self-identifies as test ---
  domain_in_url "$TEST_PUBLIC_URL" "$TEST_EXPECTED_DOMAIN" || {
    echo "ERROR: safety guard A failed." >&2
    echo "  This box's SUPABASE_PUBLIC_URL ($TEST_PUBLIC_URL)" >&2
    echo "  does not contain TEST_EXPECTED_DOMAIN ($TEST_EXPECTED_DOMAIN)." >&2
    echo "  Refusing — this may be the PROD box or a misconfiguration." >&2
    exit 1; }

  # --- Connectivity: local test DB must be up before we probe further ---
  ( cd "$TEST_DIR" && docker compose exec -T db pg_isready -U postgres ) >/dev/null 2>&1 || {
    echo "ERROR: test DB not accepting connections (cd $TEST_DIR && docker compose exec db pg_isready)" >&2
    echo "       Start the test stack first: (cd $TEST_DIR && docker compose up -d)" >&2
    exit 1; }

  # --- Guard B: source != target (read prod's public URL over SSH) ---
  # `|| true` so an SSH/read failure falls through to the diagnostic below instead
  # of aborting mid-substitution under `set -e`/`pipefail`. Strip CR + surrounding
  # quotes the same way read_env_value does, so prod and test are compared symmetrically.
  PROD_PUBLIC_URL="$(ssh "$PROD_SSH" "grep -E '^[[:space:]]*SUPABASE_PUBLIC_URL=' '$PROD_DIR/.env' | head -n1 | cut -d= -f2-" 2>/dev/null | tr -d '\r' || true)"
  PROD_PUBLIC_URL="${PROD_PUBLIC_URL#\"}"; PROD_PUBLIC_URL="${PROD_PUBLIC_URL%\"}"
  PROD_PUBLIC_URL="${PROD_PUBLIC_URL#\'}"; PROD_PUBLIC_URL="${PROD_PUBLIC_URL%\'}"
  [[ -n "$PROD_PUBLIC_URL" ]] || {
    echo "ERROR: could not read prod SUPABASE_PUBLIC_URL over SSH ($PROD_SSH : $PROD_DIR/.env)" >&2
    echo "       Check PROD_SSH / PROD_DIR and that this box can SSH to prod." >&2
    exit 1; }
  [[ "$PROD_PUBLIC_URL" != "$TEST_PUBLIC_URL" ]] || {
    echo "ERROR: safety guard B failed — prod and test SUPABASE_PUBLIC_URL are identical:" >&2
    echo "  $TEST_PUBLIC_URL" >&2
    echo "  Source and target must differ. Refusing." >&2
    exit 1; }

  # --- Guard C: migration parity (max(name) + count from public._migrations) ---
  # `|| true` on each capture so a read failure falls through to the explicit
  # checks below rather than aborting mid-substitution under `set -e`/`pipefail`.
  local prod_max prod_cnt test_max test_cnt
  prod_max="$(ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db psql -tA -U postgres -d postgres -c \"SELECT COALESCE(max(name),'') FROM public._migrations\"" 2>/dev/null | tr -d '\r' || true)"
  prod_cnt="$(ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db psql -tA -U postgres -d postgres -c 'SELECT count(*) FROM public._migrations'" 2>/dev/null | tr -d '\r' || true)"
  test_max="$( ( cd "$TEST_DIR" && docker compose exec -T db psql -tA -U postgres -d postgres -c "SELECT COALESCE(max(name),'') FROM public._migrations" ) 2>/dev/null | tr -d '\r' || true)"
  test_cnt="$( ( cd "$TEST_DIR" && docker compose exec -T db psql -tA -U postgres -d postgres -c 'SELECT count(*) FROM public._migrations' ) 2>/dev/null | tr -d '\r' || true)"
  # count(*) is "0" for an empty table and "" only when the probe itself failed,
  # so empty counts mean a failed read — abort rather than let an all-empty
  # "match" pass Guard C spuriously.
  [[ -n "$prod_cnt" && -n "$test_cnt" ]] || {
    echo "ERROR: could not read public._migrations from prod and/or test (SSH/compose error?)." >&2
    echo "  prod: max=[$prod_max] count=[$prod_cnt]   test: max=[$test_max] count=[$test_cnt]" >&2
    exit 1; }
  migrations_match "$prod_max" "$prod_cnt" "$test_max" "$test_cnt" || {
    echo "ERROR: safety guard C failed — migration state differs between prod and test:" >&2
    echo "  prod: max=[$prod_max] count=[$prod_cnt]" >&2
    echo "  test: max=[$test_max] count=[$test_cnt]" >&2
    echo "  Deploy/pull the test server to prod's migration version first, then re-run." >&2
    exit 1; }

  echo "==> Guards passed."
  echo "    source (read-only): $PROD_SSH   $PROD_PUBLIC_URL"
  echo "    target (this box) : $TEST_DIR   $TEST_PUBLIC_URL"

  if ! $ASSUME_YES && ! $DRY_RUN; then
    echo ""
    echo "This will REPLACE ALL DATA in the TEST database with production data."
    printf "Continue? [y/N] "
    read -r ans || true
    [[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  fi
}
```

- [ ] **Step 2: Verify syntax, lint, and that unit tests still pass**

Run: `bash -n scripts/sync-prod-to-test.sh && shellcheck scripts/sync-prod-to-test.sh && bash scripts/test/test-sync-test-helpers.sh`
Expected: no syntax errors; shellcheck clean (the `source` line carries its `# shellcheck disable=SC1090`); unit tests still `passed: 25, failed: 0` (sourcing the script with the real `preflight` defined must NOT run it — the `BASH_SOURCE` guard prevents that).

- [ ] **Step 3: Commit**

```bash
git add scripts/sync-prod-to-test.sh
git commit -m "feat(scripts): preflight + layered guard (domain self-ID, source!=target, migration parity)"
```

---

### Task 6: `dump_prod()` + `fetch_images()`

**Files:**
- Modify: `scripts/sync-prod-to-test.sh` (replace both stubs)

- [ ] **Step 1: Replace `dump_prod()`**

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

- [ ] **Step 2: Replace `fetch_images()`**

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

- [ ] **Step 3: Verify syntax + lint**

Run: `bash -n scripts/sync-prod-to-test.sh && shellcheck scripts/sync-prod-to-test.sh`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add scripts/sync-prod-to-test.sh
git commit -m "feat(scripts): dump_prod + fetch_images (read-only pull from prod over SSH)"
```

---

### Task 7: `restore_db()` — atomic local restore

**Files:**
- Modify: `scripts/sync-prod-to-test.sh` (replace stub)

- [ ] **Step 1: Replace `restore_db()`**

```bash
restore_db() {
  local public_tables truncate_stmt
  public_tables="$( ( cd "$TEST_DIR" && docker compose exec -T db psql -tA -U postgres -d postgres -c \
    "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname='public'" ) 2>/dev/null | tr -d '\r' || true )"
  [[ -n "$public_tables" ]] || { echo "ERROR: could not list public tables in the test DB (is the test stack up?)" >&2; exit 1; }
  truncate_stmt="$(build_truncate_stmt "$public_tables")"

  if $DRY_RUN; then
    echo "[dry-run] would restore into the TEST db inside one transaction:"
    echo "  BEGIN; SET session_replication_role = replica;"
    echo "  $truncate_stmt"
    echo "  <auth.sql> ; <public.sql>"
    echo "  SET session_replication_role = default; COMMIT;"
    return 0
  fi

  echo "==> Restoring into test (single transaction, triggers/FK off)..."
  {
    echo "BEGIN;"
    echo "SET session_replication_role = replica;"
    echo "$truncate_stmt"
    cat "$WORKDIR/auth.sql"
    cat "$WORKDIR/public.sql"
    echo "SET session_replication_role = default;"
    echo "COMMIT;"
  } | ( cd "$TEST_DIR" && docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres )
}
```

- [ ] **Step 2: Verify syntax + lint + unit tests**

Run: `bash -n scripts/sync-prod-to-test.sh && shellcheck scripts/sync-prod-to-test.sh && bash scripts/test/test-sync-test-helpers.sh`
Expected: clean; `passed: 25, failed: 0`.

- [ ] **Step 3: Commit**

```bash
git add scripts/sync-prod-to-test.sh
git commit -m "feat(scripts): restore_db — atomic local truncate+load via docker compose exec"
```

---

### Task 8: `upload_images()` — Storage-API re-ingest

**Files:**
- Modify: `scripts/sync-prod-to-test.sh` (replace stub)

- [ ] **Step 1: Replace `upload_images()`**

```bash
upload_images() {
  local namedir obj file mime code total=0 fails=0
  if $DRY_RUN; then
    echo "[dry-run] would upload each product-images object via POST $TEST_SUPABASE_URL/storage/v1/object/product-images/<name>"
    return 0
  fi
  [[ -d "$WORKDIR/product-images" ]] || { echo "No images to upload."; return 0; }

  echo "==> Uploading product images to the test Storage API ($TEST_SUPABASE_URL)..."
  # process substitution (not a pipe) so the counters persist in this shell
  while IFS= read -r namedir; do
    obj="$(basename "$namedir")"
    file="$(ls -t "$namedir" 2>/dev/null | head -n1)"
    [[ -n "$file" ]] || continue
    file="$namedir/$file"
    mime="$(mime_for "$obj")"
    total=$((total+1))
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      "$TEST_SUPABASE_URL/storage/v1/object/product-images/$obj" \
      -H "Authorization: Bearer $TEST_SERVICE_KEY" \
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

- [ ] **Step 2: Verify syntax + lint**

Run: `bash -n scripts/sync-prod-to-test.sh && shellcheck scripts/sync-prod-to-test.sh`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add scripts/sync-prod-to-test.sh
git commit -m "feat(scripts): upload_images — re-ingest via the test box's local Storage API"
```

---

### Task 9: `verify_and_cleanup()` + final wiring check

**Files:**
- Modify: `scripts/sync-prod-to-test.sh` (replace stub)

- [ ] **Step 1: Replace `verify_and_cleanup()`**

```bash
verify_and_cleanup() {
  echo "==> Row counts in test:"
  ( cd "$TEST_DIR" && docker compose exec -T db psql -U postgres -d postgres -c "
    SELECT 'auth.users'            AS entity, count(*) FROM auth.users
    UNION ALL SELECT 'companies',      count(*) FROM public.companies
    UNION ALL SELECT 'embeddeds',      count(*) FROM public.embeddeds
    UNION ALL SELECT 'vendingMachine', count(*) FROM public.\"vendingMachine\"
    UNION ALL SELECT 'products',       count(*) FROM public.products
    UNION ALL SELECT 'sales',          count(*) FROM public.sales
    UNION ALL SELECT 'storage(images)',count(*) FROM storage.objects WHERE bucket_id='product-images';" )

  if [[ -d "$WORKDIR/product-images" ]]; then
    local local_imgs
    local_imgs="$(find "$WORKDIR/product-images" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    echo "Local image objects fetched: $local_imgs (storage(images) below this = uploads skipped for size/mime)."
  fi

  if ! $KEEP_DUMPS; then rm -f "$WORKDIR/public.sql" "$WORKDIR/auth.sql"; fi
  if $CLEAN_CACHE; then rm -rf "$WORKDIR/product-images"; fi
}
```

- [ ] **Step 2: Full static verification**

Run: `bash -n scripts/sync-prod-to-test.sh && bash scripts/test/test-sync-test-helpers.sh && bash scripts/sync-prod-to-test.sh --help`
Then, if installed: `shellcheck scripts/sync-prod-to-test.sh` (skip if not installed — do not fail the task).
Expected: no syntax errors; `passed: 25, failed: 0`; help prints; shellcheck clean. Confirm no `TODO` stubs remain: `grep -n 'TODO' scripts/sync-prod-to-test.sh` returns nothing.

- [ ] **Step 3: Commit**

```bash
git add scripts/sync-prod-to-test.sh
git commit -m "feat(scripts): verify_and_cleanup — row counts + dump/cache cleanup"
```

---

### Task 10: README documentation

**Files:**
- Modify: `scripts/README.md` (add a section after the existing `sync-prod-to-dev.sh` section)

- [ ] **Step 1: Append the section**

Add to `scripts/README.md`:
```markdown

## sync-prod-to-test.sh

Refreshes the **test server's** database + product images with **production data**.
Run it **on the test box** (from the repo checkout there). It pulls prod read-only
over SSH and does all destructive work locally against this box's own `Docker/`
stack, so you log into test with your **production credentials**.
Design: `docs/superpowers/specs/2026-06-08-prod-to-test-data-sync-design.md`.

### Prerequisites
- Run on the test server, where the full stack is up: `(cd Docker && docker compose up -d)`
- Tools on PATH: `docker`, `ssh`, `rsync`, `curl`
- This box has an (ideally read-only) SSH key authorised on the prod host
- Test is deployed at the **same migration version** as prod (the script aborts otherwise)

### Setup
```bash
cp scripts/sync-prod-to-test.env.example scripts/sync-prod-to-test.env
# edit: PROD_SSH, PROD_DIR, PROD_STORAGE_DIR, TEST_EXPECTED_DOMAIN
```

### Run
```bash
./scripts/sync-prod-to-test.sh            # prompts before replacing the test DB
./scripts/sync-prod-to-test.sh --dry-run  # runs the read-only guards + prints planned actions
./scripts/sync-prod-to-test.sh --skip-images
./scripts/sync-prod-to-test.sh --yes      # unattended (cron)
```

### Safety
- Prod is **read-only** (`pg_dump` + `rsync` + reading `$PROD_DIR/.env`).
- Layered guard before any write: (A) this box's `SUPABASE_PUBLIC_URL` must contain
  `TEST_EXPECTED_DOMAIN`; (B) prod's and test's `SUPABASE_PUBLIC_URL` must differ;
  (C) prod and test must be at the same `public._migrations` state, else it aborts.
- The restore is one transaction; any error rolls back and leaves the test DB untouched.
- The restore target is always this box's own compose `db` service — never a remote DB.
- It does **not** use `supabase db reset` and does **not** run migrations.

### Scheduling (optional — a refresh overwrites the test DB, so opt in deliberately)
cron on the test box (weekly, Mon 04:00):
```cron
# 0 4 * * 1 cd /path/to/mdb-esp32-cashless && ./scripts/sync-prod-to-test.sh --yes >> tmp/sync-test/cron.log 2>&1
```
```

- [ ] **Step 2: Commit**

```bash
git add scripts/README.md
git commit -m "docs(scripts): document sync-prod-to-test.sh (prereqs, run, safety, scheduling)"
```

---

### Task 11: Manual acceptance on the test box (user-run)

> These steps require the real test server (SSH to prod + a running test stack) and are run by the operator on the test box. They map to the spec's Verification section. Not automatable in this repo's CI.

- [ ] **Step 1: Guard A negative test** — on a box whose `Docker/.env` `SUPABASE_PUBLIC_URL` does NOT contain `TEST_EXPECTED_DOMAIN` (e.g. set a deliberately wrong `TEST_EXPECTED_DOMAIN`), run `./scripts/sync-prod-to-test.sh --dry-run`. Expected: aborts at guard A, no writes.
- [ ] **Step 2: Dry run** — with correct config: `./scripts/sync-prod-to-test.sh --dry-run`. Expected: "Guards passed", prints the `TRUNCATE …` and planned phases, makes no writes.
- [ ] **Step 3: Guard C negative test** — if test is intentionally one migration behind prod, expect abort with the "migration state differs" message and no writes. (Skip if prod==test; it's covered by the dry run passing.)
- [ ] **Step 4: Real run** — `./scripts/sync-prod-to-test.sh`. Confirm at the prompt. Expected: completes; prints non-zero row counts matching prod magnitudes.
- [ ] **Step 5: Login** — log into the test frontend with a **production** email + password → succeeds, shows that user's real company data.
- [ ] **Step 6: Image** — a product with an image in prod shows its image on test (URL 200, not 404).
- [ ] **Step 7: Idempotency** — re-run `./scripts/sync-prod-to-test.sh --yes`; no duplicate rows; images upsert.
- [ ] **Step 8: Rollback property (spec Verification #7)** — confirm atomicity: run with `--keep-dumps`, then append a deliberately invalid statement (e.g. `INSERT INTO public.does_not_exist VALUES (1);`) to `tmp/sync-test/public.sql` and re-run the restore. Expected: psql stops at `ON_ERROR_STOP=1`, the transaction rolls back, and the prior test row counts are unchanged. Delete the corrupted dump afterward.

---

## Done criteria

- `scripts/sync-prod-to-test.sh` exists, is executable, shellcheck-clean, with no `TODO` stubs.
- `bash scripts/test/test-sync-test-helpers.sh` → `passed: 25, failed: 0`.
- `scripts/sync-prod-to-test.env.example`, the `sample.env` fixture, the `.gitignore` entries, and the `scripts/README.md` section are committed.
- Manual acceptance (Task 11) passes on the test box.
