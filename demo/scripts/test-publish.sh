#!/usr/bin/env bash
# Test-publish all Move packages against the active sui CLI network, sharing
# one ephemeral pubfile (Pub.<network>.toml at the repo root), then upgrade
# auditor_a to add the AuditV2 schema, and register every Display so the
# demo can render attestations.
#
# Packages (publish order matters — deps before dependents):
#   packages/attestations  -> shared Registry singleton (created in init)
#   demo/auditor_a         -> Audit schema (later upgraded to add AuditV2)
#   demo/auditor_b             -> a second auditor (Auditor B), NOT in the trusted set
#   demo/dependency_example        -> a subject, and a dependency of subject_example
#                                     (upgraded to v2, so it has two versions)
#   demo/subject_example           -> the browsable subject (depends on dependency_example)
#
# The AuditV2 schema lives in demo/auditor_a/upgrade/audit_v2.move,
# outside sources/ so it is absent from the initial publish. We copy it into
# sources/ only for the upgrade step, so AuditV2's defining package id is the
# *upgraded* id — exercising the schema-evolution path.
#
# Prints the Registry shared-object id so it can be exported as REGISTRY_ID
# for the demo.
#
# Usage:
#   ./demo/scripts/test-publish.sh                  # uses Pub.localnet.toml at repo root
#   ./demo/scripts/test-publish.sh /custom/path.toml

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUBFILE="${1:-$REPO_ROOT/Pub.localnet.toml}"
PUBFILE="$(cd "$(dirname "$PUBFILE")" && pwd)/$(basename "$PUBFILE")"

# Override SUI to point at a specific sui CLI (e.g., a main-built one with
# gRPC support for talking to a sui-fork localnet). Defaults to `sui` on PATH.
SUI="${SUI:-sui}"

# Sui's system display registry is a well-known shared object.
DISPLAY_REGISTRY=0xd
GAS_BUDGET=100000000

# The staged AuditV2 upgrade module and its transient location under sources/.
AUDIT_DIR="$REPO_ROOT/demo/auditor_a"
AUDIT_V2_SRC="$AUDIT_DIR/upgrade/audit_v2.move"
AUDIT_V2_STAGED="$AUDIT_DIR/sources/audit_v2.move"

# The staged dependency_v2 upgrade module and its transient location. Adding
# this module is a compatible upgrade that gives dependency_example a second
# published version (the mvr demo's version selector switches between them).
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

for pkg in packages/attestations demo/auditor_a demo/auditor_b demo/auditor_c demo/dependency_example demo/subject_example; do
    name=$(basename "$pkg")
    echo
    echo "▶ test-publish $name"
    json_out=$(mktemp); err_out=$(mktemp)
    if ! (cd "$REPO_ROOT/$pkg" \
            && "$SUI" client test-publish --build-env testnet --pubfile-path "$PUBFILE" --gas-budget "$GAS_BUDGET" --json) \
            > "$json_out" 2>"$err_out"; then
        echo "  FAILED. Output:"
        cat "$err_out" "$json_out"
        rm -f "$json_out" "$err_out"
        exit 1
    fi
    echo "  ok"
    # --json writes the result object to stdout (build logs go to stderr), so jq
    # reads it straight from json_out.
    if [[ "$name" == "attestations" ]]; then
        REGISTRY_ID=$(jq -r '
            first(.objectChanges[]?
                | select(.type == "created"
                    and (.objectType // "" | endswith("::attestations::Registry")))
                | .objectId) // empty' "$json_out")
    fi
    rm -f "$json_out" "$err_out"
done

# --- Upgrade auditor_a to add the AuditV2 schema. test-upgrade reads the
# upgrade capability from the pubfile, so we don't pass it explicitly. ---
echo
echo "▶ upgrade auditor_a (add AuditV2)"
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

# --- Upgrade dependency_example so it has two published versions. Adding the
# dependency_v2 module is a compatible upgrade; after it, the pubfile's
# published-at is the v2 id and original-id is the v1 id. ---
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

# After the upgrade, auditor_a's published-at is the v2 id (which defines
# both the `audit` and `audit_v2` modules); original-id is unchanged.
PKG_AUDIT=$(parse_pkg_field auditor_a published-at)
PKG_AUDITOR_B=$(parse_pkg_field auditor_b published-at)
PKG_AUDITOR_C=$(parse_pkg_field auditor_c published-at)

if [[ -z "$PKG_AUDIT" ]]; then
    echo "could not resolve package addresses from $PUBFILE — skipping display registration"
    echo "PKG_AUDIT=$PKG_AUDIT"
else
    register_display() {
        local label="$1" pkg="$2" module="$3" func="$4"
        echo
        echo "▶ $label"
        if ! (cd "$AUDIT_DIR" && \
                "$SUI" client call \
                    --package "$pkg" --module "$module" --function "$func" \
                    --args "$REGISTRY_ID" "$DISPLAY_REGISTRY" \
                    --gas-budget "$GAS_BUDGET" >/dev/null 2>&1); then
            echo "  FAILED (Display may already exist for this type)"
        else
            echo "  ok"
        fi
    }

    register_display register_audit_display     "$PKG_AUDIT"     audit      register_audit_display
    register_display register_auditor_b_display "$PKG_AUDITOR_B" audit      register_audit_display
    register_display register_auditor_c_display "$PKG_AUDITOR_C" audit      register_audit_display

    # AuditV2: register its Display, then APPEND a `methodology` field via
    # add_display_field — a runtime exercise of add_display_field. The shared
    # Display and the parked DisplayCap come straight from the register tx's
    # objectChanges (no off-chain lookup needed).
    echo
    echo "▶ register_audit_v2_display + add_display_field(methodology)"
    if v2reg=$(cd "$AUDIT_DIR" && "$SUI" client call \
            --package "$PKG_AUDIT" --module audit_v2 --function register_audit_v2_display \
            --args "$REGISTRY_ID" "$DISPLAY_REGISTRY" \
            --gas-budget "$GAS_BUDGET" --json 2>/dev/null); then
        V2_DISPLAY=$(printf '%s' "$v2reg" | jq -r '.objectChanges[] | select(.objectType | test("display_registry::Display<.*AuditV2")) | .objectId')
        V2_CAP=$(printf '%s' "$v2reg" | jq -r '.objectChanges[] | select(.objectType | test("display_registry::DisplayCap<.*AuditV2")) | .objectId')
        if "$SUI" client ptb \
                --move-call "$PKG_AUDIT::audit_v2::add_audit_v2_methodology_display" "@$REGISTRY_ID" "@$V2_DISPLAY" "@$V2_CAP" \
                >/dev/null 2>&1; then
            echo "  ok (+methodology)"
        else
            echo "  add_display_field FAILED"
        fi
    else
        echo "  register_audit_v2_display FAILED (Display may already exist)"
    fi
fi

echo
echo "✓ all packages test-published and auditor_a upgraded"
if [[ -n "$REGISTRY_ID" ]]; then
    echo
    echo "Registry shared object: $REGISTRY_ID"
    echo
    echo "Run the demo with:"
    echo "  REGISTRY_ID=$REGISTRY_ID bash demo/scripts/demo.sh"
else
    echo
    echo "(couldn't extract Registry id from the attestations package's publish output;"
    echo " look it up via the publish tx digest, then export it as REGISTRY_ID.)"
fi
