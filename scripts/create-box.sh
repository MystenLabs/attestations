#!/usr/bin/env bash
# Create a subject's two boxes (active + revoked) and echo the ACTIVE box id —
# the one whose BoxKey.revoked is false, where attestations live. Reusable CLI
# op over create_box.
#
# Usage: create-box.sh <registry-pkg> <registry-id> <subject-id>
set -euo pipefail
REGPKG=$1; REGISTRY=$2; SUBJECT=$3

out=$(sui client ptb \
    --move-call "$REGPKG::attestations::create_box" "@$REGISTRY" "@$SUBJECT" \
    --json)

# create_box makes two boxes; echo the active one (BoxKey.revoked == false).
for box in $(echo "$out" | jq -r '.objectChanges[] | select(.objectType | endswith("::Box")) | .objectId'); do
    revoked=$(sui client object "$box" --json | jq -r '.content.key.revoked')
    [ "$revoked" = false ] && { echo "$box"; exit 0; }
done
echo "create-box: no active box created" >&2; exit 1
