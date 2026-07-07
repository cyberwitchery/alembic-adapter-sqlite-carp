#!/usr/bin/env bash
# real alembic-driven end-to-end test: has the actual alembic cli spawn this
# adapter and converge an inventory through plan/apply, then verifies the second
# plan is empty (idempotent) and that update/delete flow through.
#
# needs the alembic cli built. point $ALEMBIC at it, or this script looks for it
# under ../alembic/target/{release,debug}/alembic. CI runs this in the
# e2e-alembic job against a cargo-installed alembic cli.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

ALEMBIC="${ALEMBIC:-}"
# a bare command name on PATH (e.g. ALEMBIC=alembic, as ci passes it) -> path
if [ -n "$ALEMBIC" ] && [ ! -x "$ALEMBIC" ]; then
  resolved="$(command -v "$ALEMBIC" 2>/dev/null || true)"
  [ -n "$resolved" ] && ALEMBIC="$resolved"
fi
if [ -z "$ALEMBIC" ]; then
  # absolute, because the run below cds into a temp workdir
  for c in "$ROOT/../alembic/target/release/alembic" "$ROOT/../alembic/target/debug/alembic"; do
    [ -x "$c" ] && ALEMBIC="$c" && break
  done
fi
if [ -z "$ALEMBIC" ] || [ ! -x "$ALEMBIC" ]; then
  echo "SKIP: alembic cli not found. set \$ALEMBIC to the alembic binary."
  exit 0
fi

command -v python3 >/dev/null || { echo "need python3"; exit 1; }

carp -b alembic-sqlite.carp || { echo "adapter build failed"; exit 1; }
ADAPTER="$ROOT/out/alembic-adapter-sqlite"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/backend.yaml" <<EOF
backend: external
command: $ADAPTER
setup:
  path: $WORK/store.db
EOF

cat > "$WORK/inv.yaml" <<'EOF'
schema:
  types:
    dcim.site:
      key: { slug: { type: slug } }
      fields:
        name:   { type: string }
        slug:   { type: slug }
        status: { type: string }
    dcim.device:
      key: { name: { type: slug } }
      fields:
        name:   { type: string }
        site:   { type: ref, target: dcim.site }
        status: { type: string }
objects:
  - uid: "a4d6a0c3-4e73-4a76-b216-4d38f8c55f3d"
    type: dcim.site
    key:   { slug: "fra1" }
    attrs: { name: "FRA1", slug: "fra1", status: "active" }
  - uid: "7b8f7a92-8fd0-4667-9a4b-9f3b5c9a4b1a"
    type: dcim.device
    key:   { name: "leaf01" }
    attrs: { name: "leaf01", site: "a4d6a0c3-4e73-4a76-b216-4d38f8c55f3d", status: "active" }
EOF

cd "$WORK"
fail=0
B=(--backend external --backend-config backend.yaml)

ops_count() { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('ops',[])))" "$1"; }
expect() { # <desc> <actual> <wanted>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (got $2, wanted $3)"; fail=1; fi
}

"$ALEMBIC" validate -f inv.yaml >/dev/null || { echo "FAIL - validate"; fail=1; }

"$ALEMBIC" plan -f inv.yaml -o p1.json "${B[@]}" >/dev/null
expect "initial plan has 2 creates" "$(ops_count p1.json)" "2"

"$ALEMBIC" apply -p p1.json "${B[@]}" >/dev/null

"$ALEMBIC" plan -f inv.yaml -o p2.json "${B[@]}" >/dev/null
expect "re-plan is empty (converged)" "$(ops_count p2.json)" "0"

# update: flip status
sed 's/status: "active"/status: "planned"/g' inv.yaml > inv2.yaml
"$ALEMBIC" plan -f inv2.yaml -o p3.json "${B[@]}" >/dev/null
expect "edited inventory plans updates" "$(ops_count p3.json)" "2"
"$ALEMBIC" apply -p p3.json "${B[@]}" >/dev/null
got="$(sqlite3 store.db "SELECT json_extract(attrs_json,'\$.status') FROM alembic_objects WHERE type_name='dcim.site';")"
expect "update persisted to sqlite" "$got" "planned"

# delete: same intent minus the device (written directly so we need no yaml lib)
cat > inv3.yaml <<'EOF'
schema:
  types:
    dcim.site:
      key: { slug: { type: slug } }
      fields:
        name:   { type: string }
        slug:   { type: slug }
        status: { type: string }
    dcim.device:
      key: { name: { type: slug } }
      fields:
        name:   { type: string }
        site:   { type: ref, target: dcim.site }
        status: { type: string }
objects:
  - uid: "a4d6a0c3-4e73-4a76-b216-4d38f8c55f3d"
    type: dcim.site
    key:   { slug: "fra1" }
    attrs: { name: "FRA1", slug: "fra1", status: "planned" }
EOF
"$ALEMBIC" plan -f inv3.yaml -o p4.json "${B[@]}" --allow-delete >/dev/null
expect "removing an object plans a delete" "$(ops_count p4.json)" "1"
"$ALEMBIC" apply -p p4.json "${B[@]}" --allow-delete >/dev/null
got="$(sqlite3 store.db "SELECT count(*) FROM alembic_objects;")"
expect "delete persisted (only the site remains)" "$got" "1"

echo
if [ "$fail" -eq 0 ]; then echo "e2e-alembic: all checks passed"; else echo "e2e-alembic: failures above"; fi
exit "$fail"
