#!/usr/bin/env bash
# Follow examples/auditor/README.md's onboarding guide on a localnet, the way a
# new auditor would: publish a copy of the template, register its Display,
# publish two reports about a subject, create the subject's box, and revoke one
# of the reports.
#
# The copy's registry dependency points at this checkout's registry
# (scripts/copy-template.sh), which test-publish finds in PUBFILE.
#
# e2e/run.sh calls this with the sui client already on the localnet and funded.
#
# Usage: PUBFILE=... REGISTRY_ID=... SUBJECT=... bash e2e/walkthrough.sh <work-dir>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPS="$REPO_ROOT/scripts"
SUI="${SUI:-sui}"
PUBFILE="${PUBFILE:?PUBFILE is required}"
REGISTRY="${REGISTRY_ID:?REGISTRY_ID is required}"
SUBJECT="${SUBJECT:?SUBJECT is required}"
WORK="${1:?usage: walkthrough.sh <work-dir>}"

DISPLAY_REGISTRY=0xd    # the system display registry
PUBDATE=1748736000000   # 2025-06-01, the same fixed date as demo.sh

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
KEPT=$(bash "$OPS/attest-audit.sh" "$PKG" "$CAP" "$REGISTRY" "$SUBJECT" \
    "Walkthrough report — kept" "https://auditor.example/kept.pdf" "$PUBDATE")
SUPERSEDED=$(bash "$OPS/attest-audit.sh" "$PKG" "$CAP" "$REGISTRY" "$SUBJECT" \
    "Walkthrough report — revoked" "https://auditor.example/revoked.pdf" "$PUBDATE")
echo "  kept $KEPT, to revoke $SUPERSEDED"

echo "▶ create the subject's box, then revoke one report (guide: revoking)"
BOX=$(bash "$OPS/create-box.sh" "$REGPKG" "$REGISTRY" "$SUBJECT")
bash "$OPS/revoke-audit.sh" "$PKG" "$CAP" "$BOX" "$SUPERSEDED"
echo "  revoked $SUPERSEDED from box $BOX"
