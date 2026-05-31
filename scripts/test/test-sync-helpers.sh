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
check "mime JPEG upper" "$(mime_for A.JPEG)"   "image/jpeg"
check "mime WEBP upper" "$(mime_for A.WEBP)"   "image/webp"

# --- dev_db_container ---
check "container from fixture" "$(dev_db_container "$HERE/fixtures/config.toml")" "supabase_db_test-project"
err_out="$( ( set -e; set -o pipefail; dev_db_container "$HERE/fixtures/no-project.toml" ) 2>&1 1>/dev/null )"
case "$err_out" in *"project_id not found"*) _case_result="ok" ;; *) _case_result="no" ;; esac
check "missing project_id errors gracefully" "$_case_result" "ok"

# --- dump_looks_like_sql ---
dump_looks_like_sql "$HERE/fixtures/good-dump.sql";       check_rc "good dump accepted"      "$?" "0"
dump_looks_like_sql "$HERE/fixtures/bad-dump.txt";       check_rc "bad dump rejected"       "$?" "1"
dump_looks_like_sql "$HERE/fixtures/empty.sql";          check_rc "empty dump rejected"     "$?" "1"
dump_looks_like_sql "$HERE/fixtures/set-first-dump.sql";       check_rc "SET-first dump accepted"    "$?" "0"
dump_looks_like_sql "$HERE/fixtures/select-first-dump.sql";    check_rc "SELECT-first dump accepted" "$?" "0"
dump_looks_like_sql "$HERE/fixtures/backslash-dump.sql";       check_rc "backslash-first dump accepted" "$?" "0"

# --- build_truncate_stmt ---
check "truncate stmt" "$(build_truncate_stmt 'public.a, public.b')" \
  "TRUNCATE public.a, public.b, auth.users CASCADE;"

echo "----"
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
