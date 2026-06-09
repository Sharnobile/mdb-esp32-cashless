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

# --- read_env_value ---
check "env: plain url"        "$(read_env_value "$HERE/fixtures/sample.env" SUPABASE_PUBLIC_URL)" "https://test.vmflow.example"
check "env: quoted jwt + =="  "$(read_env_value "$HERE/fixtures/sample.env" SERVICE_ROLE_KEY)"    "eyJhbGciOiJIUzI1NiJ.padding=="
check "env: value with space" "$(read_env_value "$HERE/fixtures/sample.env" STUDIO_DEFAULT_ORGANIZATION)" "Default Organization"
check "env: single-quoted"    "$(read_env_value "$HERE/fixtures/sample.env" QUOTED_SINGLE)"       "hello world"
read_env_value "$HERE/fixtures/sample.env" NOT_PRESENT; check_rc "env: missing key rc=1" "$?" "1"
read_env_value "$HERE/fixtures/does-not-exist.env" SUPABASE_PUBLIC_URL; check_rc "env: missing file rc=1" "$?" "1"

# --- domain_in_url (Guard A decision) ---
domain_in_url "https://test.vmflow.example" "test.vmflow.example"; check_rc "domain match"       "$?" "0"
domain_in_url "https://prod.vmflow.example" "test.vmflow.example"; check_rc "domain mismatch"    "$?" "1"
domain_in_url "https://test.vmflow.example" "";                    check_rc "empty domain rc=1"  "$?" "1"

# --- migrations_match (Guard C decision): args = prod_max prod_count test_max test_count ---
migrations_match "20260608_x" "100" "20260608_x" "100"; check_rc "migrations equal"        "$?" "0"
migrations_match "20260608_x" "100" "20260608_x" "99";  check_rc "migrations count differs" "$?" "1"
migrations_match "20260608_x" "100" "20260607_y" "100"; check_rc "migrations max differs"   "$?" "1"

echo "----"
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
