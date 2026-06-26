#!/usr/bin/env bash
# Test-publish all Move packages against the active sui CLI network, sharing
# one ephemeral pubfile (Pub.<network>.toml at the repo root), then upgrade
# audit_example to add the AuditV2 schema, and register every Display so the
# demo can render attestations.
#
# Packages (publish order matters — deps before dependents):
#   packages/attestation_registry  -> shared Registry singleton (created in init)
#   examples/audit_example         -> Audit schema (later upgraded to add AuditV2)
#   demo/dependency_example        -> a subject, and a dependency of subject_example
#   demo/subject_example           -> the browsable subject (depends on dependency_example)
#   demo/untrusted_example         -> attester not in the trusted set (filtered out)
#
# The AuditV2 schema lives in examples/audit_example/upgrade/audit_v2.move,
# outside sources/ so it is absent from the initial publish. We copy it into
# sources/ only for the upgrade step, so AuditV2's defining package id is the
# *upgraded* id — exercising the schema-evolution path.
#
# Prints the Registry shared-object id so it can be exported as REGISTRY_ID
# for the TS demo.
#
# Usage:
#   ./scripts/test-publish.sh                  # uses Pub.localnet.toml at repo root
#   ./scripts/test-publish.sh /custom/path.toml

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBFILE="${1:-$REPO_ROOT/Pub.localnet.toml}"
PUBFILE="$(cd "$(dirname "$PUBFILE")" && pwd)/$(basename "$PUBFILE")"

# Override SUI to point at a specific sui CLI (e.g., a main-built one with
# gRPC support for talking to a sui-fork localnet). Defaults to `sui` on PATH.
SUI="${SUI:-sui}"

# Sui's system display registry is a well-known shared object.
DISPLAY_REGISTRY=0xd
GAS_BUDGET=100000000

# The staged AuditV2 upgrade module and its transient location under sources/.
AUDIT_DIR="$REPO_ROOT/examples/audit_example"
AUDIT_V2_SRC="$AUDIT_DIR/upgrade/audit_v2.move"
AUDIT_V2_STAGED="$AUDIT_DIR/sources/audit_v2.move"

# The dependency_example v2 upgrade module, staged the same way. Its upgrade
# runs *after* subject_example is published, so the subject's linkage pins
# dependency v1 while v2 is a newer version the demo can attest a vuln against.
DEP_DIR="$REPO_ROOT/demo/dependency_example"
DEP_V2_SRC="$DEP_DIR/upgrade/dependency_v2.move"
DEP_V2_STAGED="$DEP_DIR/sources/dependency_v2.move"

# Always start the upgrade modules un-staged so the initial publish is v1-only,
# even if a prior run died mid-upgrade and left a copy behind.
rm -f "$AUDIT_V2_STAGED" "$DEP_V2_STAGED"

# Remove any prior pubfile so test-publish starts each package from a clean
# slate. Otherwise existing entries cause re-publish errors.
if [[ -f "$PUBFILE" ]]; then
    echo "removing prior pubfile: $PUBFILE"
    rm -f "$PUBFILE"
fi

echo "shared pubfile: $PUBFILE"

REGISTRY_ID=""

# Find the substring [start..end] of `data` that's a balanced JSON object,
# parse it, and dump it back. Tolerates non-JSON text around the JSON block
# (compiler warnings, status lines, etc.). On failure prints nothing.
extract_json() {
    python3 - "$1" <<'PY'
import sys, json
data = open(sys.argv[1]).read()
start = data.find('{')
end = data.rfind('}')
if start < 0 or end <= start:
    sys.exit(0)
try:
    json.dumps(json.loads(data[start:end+1]))
except Exception:
    sys.exit(0)
print(data[start:end+1])
PY
}

# Read a field ("published-at", "original-id", "upgrade-capability") from the
# pubfile [[published]] block whose source dir matches the given package name.
parse_pkg_field() {
    python3 - "$PUBFILE" "$1" "$2" <<'PY'
import re, sys
pubfile, target, field = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(pubfile).read()
for block in content.split('[[published]]'):
    if '/' + target in block:
        m = re.search(field + r'\s*=\s*"([^"]+)"', block)
        if m:
            print(m.group(1)); break
PY
}

for pkg in packages/attestation_registry examples/audit_example examples/vuln_example examples/self_pull demo/dependency_example demo/subject_example demo/untrusted_example; do
    name=$(basename "$pkg")
    echo
    echo "▶ test-publish $name"
    json_out=$(mktemp)
    if ! (cd "$REPO_ROOT/$pkg" \
            && "$SUI" client test-publish --build-env testnet --pubfile-path "$PUBFILE" --gas-budget "$GAS_BUDGET" --json) \
            > "$json_out" 2>&1; then
        echo "  FAILED. Output:"
        cat "$json_out"
        rm -f "$json_out"
        exit 1
    fi
    echo "  ok"
    if [[ "$name" == "attestation_registry" ]]; then
        json=$(extract_json "$json_out" || true)
        if [[ -n "$json" ]]; then
            REGISTRY_ID=$(python3 -c "
import json, sys
r = json.loads(sys.stdin.read())
for c in r.get('objectChanges', []):
    t = c.get('objectType', '')
    if t.endswith('::attestation_registry::Registry') and c.get('type') == 'created':
        print(c['objectId']); break
" <<<"$json")
        fi
    fi
    rm -f "$json_out"
done

# --- Upgrade audit_example to add the AuditV2 schema. test-upgrade reads the
# upgrade capability from the pubfile, so we don't pass it explicitly. ---
echo
echo "▶ upgrade audit_example (add AuditV2)"
cp "$AUDIT_V2_SRC" "$AUDIT_V2_STAGED"
upgrade_out=$(mktemp)
if ! (cd "$AUDIT_DIR" \
        && "$SUI" client test-upgrade \
            --build-env testnet --pubfile-path "$PUBFILE" --gas-budget "$GAS_BUDGET") \
        > "$upgrade_out" 2>&1; then
    echo "  FAILED. Output:"
    cat "$upgrade_out"
    rm -f "$upgrade_out" "$AUDIT_V2_STAGED"
    exit 1
fi
rm -f "$upgrade_out" "$AUDIT_V2_STAGED"
echo "  ok"

# --- Upgrade dependency_example to v2. subject_example was published in the
# loop above (pinning dependency v1), so this upgrade just makes a newer
# version exist; the subject's linkage still points at v1. ---
echo
echo "▶ upgrade dependency_example (v2)"
cp "$DEP_V2_SRC" "$DEP_V2_STAGED"
dep_upgrade_out=$(mktemp)
if ! (cd "$DEP_DIR" \
        && "$SUI" client test-upgrade \
            --build-env testnet --pubfile-path "$PUBFILE" --gas-budget "$GAS_BUDGET") \
        > "$dep_upgrade_out" 2>&1; then
    echo "  FAILED. Output:"
    cat "$dep_upgrade_out"
    rm -f "$dep_upgrade_out" "$DEP_V2_STAGED"
    exit 1
fi
rm -f "$dep_upgrade_out" "$DEP_V2_STAGED"
echo "  ok"

# After the upgrade, audit_example's published-at is the v2 id (which defines
# both the `audit` and `audit_v2` modules); original-id is unchanged.
PKG_AUDIT=$(parse_pkg_field audit_example published-at)
PKG_VULN=$(parse_pkg_field vuln_example published-at)
PKG_SELFPULL=$(parse_pkg_field self_pull published-at)
PKG_UNTRUSTED=$(parse_pkg_field untrusted_example published-at)

if [[ -z "$PKG_AUDIT" ]] || [[ -z "$PKG_VULN" ]]; then
    echo "could not resolve package addresses from $PUBFILE — skipping display registration"
    echo "PKG_AUDIT=$PKG_AUDIT PKG_VULN=$PKG_VULN"
else
    register_display() {
        local label="$1" pkg="$2" module="$3" func="$4"
        echo
        echo "▶ $label"
        if ! (cd "$AUDIT_DIR" && \
                "$SUI" client call \
                    --package "$pkg" --module "$module" --function "$func" \
                    --args "$DISPLAY_REGISTRY" \
                    --gas-budget "$GAS_BUDGET" >/dev/null 2>&1); then
            echo "  FAILED (Display may already exist for this type)"
        else
            echo "  ok"
        fi
    }

    register_display register_audit_display     "$PKG_AUDIT"     audit      register_audit_display
    register_display register_audit_v2_display  "$PKG_AUDIT"     audit_v2   register_audit_v2_display
    register_display register_vuln_display      "$PKG_VULN"      vuln       register_vuln_display
    register_display register_self_pull_display "$PKG_SELFPULL"  self_pull  register_self_pull_display
    register_display register_untrusted_display "$PKG_UNTRUSTED" untrusted  register_untrusted_display
fi

echo
echo "✓ all packages test-published and audit_example upgraded"
if [[ -n "$REGISTRY_ID" ]]; then
    echo
    echo "Registry shared object: $REGISTRY_ID"
    echo
    echo "Run the TS demo with:"
    echo "  REGISTRY_ID=$REGISTRY_ID pnpm --dir ts demo"
else
    echo
    echo "(couldn't extract Registry id from attestation_registry's publish output;"
    echo " look it up via the publish tx digest, then export it as REGISTRY_ID.)"
fi
