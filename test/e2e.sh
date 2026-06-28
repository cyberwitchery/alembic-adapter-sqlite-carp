#!/usr/bin/env bash
# end-to-end test: drives the *compiled* adapter binary over stdin/stdout, the
# way alembic spawns it. unlike test/adapter.carp (which calls the handlers
# in-process), this exercises the real process boundary: json in, json out, a
# real sqlite file. no alembic needed; for a real alembic-driven run see
# test/e2e-alembic.sh.
set -uo pipefail

cd "$(dirname "$0")/.."

# always rebuild: test/adapter.carp inherits the adapter's Project.config title,
# so `carp -x` leaves a *test* binary at out/alembic-adapter-sqlite. rebuild here
# so we are unambiguously running the adapter, whatever ran before us.
echo "building adapter ..."
carp -b alembic-sqlite.carp || { echo "build failed"; exit 1; }
BIN="${BIN:-out/alembic-adapter-sqlite}"

DB="$(mktemp -u).db"
trap 'rm -f "$DB"' EXIT

fail=0
run() { printf '%s' "$1" | "$BIN"; }

# check <desc> <request-json> <python-bool-over-r>
check() {
  local desc="$1" req="$2" expr="$3" out
  out="$(run "$req")"
  if printf '%s' "$out" \
      | python3 -c "import sys,json; r=json.load(sys.stdin); sys.exit(0 if ($expr) else 1)" 2>/dev/null; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    echo "       response: $out"
    fail=1
  fi
}

env() { printf '{"version":1,"setup":{"path":"%s"},%s}' "$DB" "$1"; }

check "ensure_schema returns ok" \
  "$(env '"method":"ensure_schema","schema":{"types":{}}')" \
  "r['ok'] is True"

check "write create returns sequential rowids" \
  "$(env '"method":"write","schema":{"types":{}},"state":{"mappings":{}},"ops":[{"op":"create","uid":"u1","type_name":"dcim.site","desired":{"key":{"name":"site-a"},"attrs":{"asn":64512,"active":true}}},{"op":"create","uid":"u2","type_name":"dcim.site","desired":{"key":{"name":"site-b"},"attrs":{}}}]')" \
  "r['ok'] and [a['backend_id'] for a in r['result']['applied']] == [1,2]"

check "read returns both objects, ints intact" \
  "$(env '"method":"read","schema":{"types":{}},"state":{"mappings":{}},"types":["dcim.site"]')" \
  "len(r['result'])==2 and r['result'][0]['attrs']['asn']==64512 and r['result'][0]['attrs']['active'] is True and r['result'][0]['backend_id']==1"

check "update by backend_id overwrites attrs" \
  "$(env '"method":"write","schema":{"types":{}},"state":{"mappings":{}},"ops":[{"op":"update","uid":"u1","type_name":"dcim.site","backend_id":1,"desired":{"key":{"name":"site-a"},"attrs":{"asn":65000}}}]')" \
  "r['ok'] and r['result']['applied'][0]['backend_id']==1"

check "read reflects the update" \
  "$(env '"method":"read","schema":{"types":{}},"state":{"mappings":{}},"types":["dcim.site"]')" \
  "r['result'][0]['attrs']['asn']==65000"

check "delete by backend_id removes the row" \
  "$(env '"method":"write","schema":{"types":{}},"state":{"mappings":{}},"ops":[{"op":"delete","uid":"u2","type_name":"dcim.site","key":{"name":"site-b"},"backend_id":2}]')" \
  "r['ok'] and r['result']['applied'][0]['backend_id']==2"

check "read shows only the survivor" \
  "$(env '"method":"read","schema":{"types":{}},"state":{"mappings":{}},"types":["dcim.site"]')" \
  "len(r['result'])==1 and r['result'][0]['key']['name']=='site-a'"

check "unknown method is an error" \
  "$(env '"method":"teleport","schema":{"types":{}}')" \
  "r['ok'] is False and 'error' in r"

check "bad protocol version is an error" \
  '{"version":2,"setup":{},"method":"read","types":[]}' \
  "r['ok'] is False"

# malformed json: a hand-built request, not via env()
if printf '%s' '{not json' | "$BIN" | python3 -c "import sys,json; r=json.load(sys.stdin); sys.exit(0 if r['ok'] is False else 1)" 2>/dev/null; then
  echo "ok   - malformed json yields an error response, not a crash"
else
  echo "FAIL - malformed json"
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "e2e: all checks passed"
else
  echo "e2e: failures above"
fi
exit "$fail"
