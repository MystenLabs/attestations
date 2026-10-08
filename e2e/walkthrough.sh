#!/usr/bin/env bash
# Follow examples/auditor/README.md's onboarding guide on a localnet, the way a
# new auditor would: publish a copy of the template, register its Display,
# publish two reports about a subject, create the subject's box, and revoke one
# of the reports. Also check that the wrong registry reference and a caller
# who does not own the admin cap are rejected before they can change that state.
#
# The copy's registry dependency points at this checkout's registry
# (scripts/copy-template.sh), which test-publish finds in PUBFILE.
#
# e2e/run.sh calls this with the sui client already on the localnet and funded.
#
# Usage: PUBFILE=... REGISTRY_ID=... REGISTRY_REF_ID=... SUBJECT=... bash e2e/walkthrough.sh <work-dir>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPS="$REPO_ROOT/scripts"
SUI="${SUI:-sui}"
PUBFILE="${PUBFILE:?PUBFILE is required}"
REGISTRY="${REGISTRY_ID:?REGISTRY_ID is required}"
REGISTRY_REF="${REGISTRY_REF_ID:?REGISTRY_REF_ID is required}"
SUBJECT="${SUBJECT:?SUBJECT is required}"
WORK="${1:?usage: walkthrough.sh <work-dir>}"

DISPLAY_REGISTRY=0xd    # the system display registry
PUBDATE=1748736000000   # 2025-06-01, fixed so the snapshot is stable

REGPKG=$(python3 - "$PUBFILE" <<'PY'
import sys, tomllib
for pkg in tomllib.load(open(sys.argv[1], "rb"))["published"]:
    if pkg["source"]["local"].endswith("/packages/attestations"):
        print(pkg["published-at"])
PY
)

copy="$WORK/auditor"
echo "▶ copy examples/auditor, pointed at this checkout's registry"
bash "$OPS/copy-template.sh" "$copy"

echo "▶ publish it (guide step 2)"
# --json writes the result to stdout and build logs to stderr.
if ! (cd "$copy" &&
    "$SUI" client test-publish --build-env testnet --pubfile-path "$PUBFILE" --json) \
    >"$WORK/auditor-publish.json" 2>"$WORK/auditor-publish.log"; then
    cat "$WORK/auditor-publish.log" "$WORK/auditor-publish.json"
    exit 1
fi
PKG=$(jq -r 'first(.objectChanges[] | select(.type == "published") | .packageId)' "$WORK/auditor-publish.json")
CAP=$(jq -r 'first(.objectChanges[] | select(.objectType // "" | endswith("::audit::AuditAdminCap")) | .objectId)' \
    "$WORK/auditor-publish.json")
echo "  package $PKG, AuditAdminCap $CAP"

echo "▶ register its Display (guide step 2)"
"$SUI" client call --package "$PKG" --module audit --function register_audit_display \
    --args "$REGISTRY" "$DISPLAY_REGISTRY" >/dev/null

echo "▶ publish two reports (guide step 4)"
KEPT=$(bash "$OPS/attest-audit.sh" "$PKG" "$CAP" "$REGISTRY_REF" "$SUBJECT" \
    "Walkthrough report — kept" "https://auditor.example/kept.pdf" "$PUBDATE")
SUPERSEDED=$(bash "$OPS/attest-audit.sh" "$PKG" "$CAP" "$REGISTRY_REF" "$SUBJECT" \
    "Walkthrough report — revoked" "https://auditor.example/revoked.pdf" "$PUBDATE")
echo "  kept $KEPT, to revoke $SUPERSEDED"

echo "▶ create the subject's box, then revoke one report (guide: revoking)"
BOX=$(bash "$OPS/create-box.sh" "$REGPKG" "$REGISTRY" "$SUBJECT")

# These failures happen at transaction validation, outside Move unit tests.
# Require the specific error as well as a failing exit status, so a network,
# gas, or CLI syntax error cannot pass a negative test.
expect_rejection() {
    local name="$1" expected="$2"
    shift 2
    local out="$WORK/$name.log"
    if "$SUI" client ptb --gas-budget 10000000 "$@" >"$out" 2>&1; then
        echo "✘ $name unexpectedly succeeded" >&2
        cat "$out" >&2
        exit 1
    fi
    if ! grep -Eq "$expected" "$out"; then
        echo "✘ $name failed for an unexpected reason (expected $expected):" >&2
        cat "$out" >&2
        exit 1
    fi
    echo "✔ $name rejected"
}

# A real shared Registry is still the wrong type: attest needs its frozen ref.
expect_rejection wrong-registry-reference 'CommandArgumentError \{ arg_idx: 1, kind: TypeMismatch \} in command 0' \
    --move-call "$PKG::audit::attest_audit" "@$CAP" "@$REGISTRY" "@$SUBJECT" \
    '"Must not be issued"' '"https://auditor.example/rejected.pdf"' "$PUBDATE"

# Give a second signer its own gas, but leave the AuditAdminCap with the publisher.
# Keep the active address unchanged so the successful revoke below uses the owner.
UNAUTHORIZED=$("$SUI" client new-address ed25519 --json | jq -er '.address')
"$SUI" client ptb --split-coins gas '[1000000000]' --assign funding \
    --transfer-objects '[funding]' "@$UNAUTHORIZED" >/dev/null

CAP_OWNERSHIP_ERROR="Object $CAP is owned by account address .*, but given owner/signer address is $UNAUTHORIZED"
expect_rejection unauthorized-attest "$CAP_OWNERSHIP_ERROR" \
    --sender "@$UNAUTHORIZED" \
    --move-call "$PKG::audit::attest_audit" "@$CAP" "@$REGISTRY_REF" "@$SUBJECT" \
    '"Must not be issued"' '"https://auditor.example/rejected.pdf"' "$PUBDATE"
expect_rejection unauthorized-revoke "$CAP_OWNERSHIP_ERROR" \
    --sender "@$UNAUTHORIZED" \
    --move-call "$PKG::audit::revoke_audit" "@$CAP" "@$BOX" "@$SUPERSEDED"

# The authorized operation still succeeds after the rejected attempts. The final
# snapshot also checks that they emitted no registry events or extra attestations.
bash "$OPS/revoke-audit.sh" "$PKG" "$CAP" "$BOX" "$SUPERSEDED"
echo "  revoked $SUPERSEDED from box $BOX"
