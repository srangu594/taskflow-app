#!/usr/bin/env bash
# Smoke test — 8 endpoint checks
# Usage: ./scripts/smoke-test.sh <BASE_URL>
# Example: ./scripts/smoke-test.sh http://k8s-taskflow-xxxx.elb.amazonaws.com

set -euo pipefail

BASE_URL="${1:-http://localhost:8000}"
PASS=0; FAIL=0

green() { echo -e "\033[0;32m  ✅  $1\033[0m"; }
red()   { echo -e "\033[0;31m  ❌  $1\033[0m"; }

run_test() {
  local name="$1" url="$2" expect="$3"
  local body
  body=$(curl -sf --max-time 10 "$url" 2>/dev/null || echo "CURL_FAILED")
  if echo "$body" | grep -q "$expect"; then
    green "$name"; PASS=$((PASS+1))
  else
    red   "$name (expected: $expect)"; FAIL=$((FAIL+1))
  fi
}

echo ""
echo "── TaskFlow Smoke Test ── $BASE_URL"
echo "═══════════════════════════════════════"
run_test "Root endpoint"       "$BASE_URL/"                  "TaskFlow API"
run_test "Health check"        "$BASE_URL/api/health"        '"status"'
run_test "Liveness probe"      "$BASE_URL/api/health/live"   "alive"
run_test "Readiness probe"     "$BASE_URL/api/health/ready"  "ready"
run_test "List tasks"          "$BASE_URL/api/tasks/"        "["
run_test "Task stats"          "$BASE_URL/api/tasks/stats"   '"total"'
run_test "List users"          "$BASE_URL/api/users/"        "["
run_test "API docs (Swagger)"  "$BASE_URL/api/docs"          "swagger"
echo "═══════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"

[ "$FAIL" -gt "0" ] && exit 1 || echo -e "\033[0;32m  All tests passed\033[0m"
