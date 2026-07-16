#!/usr/bin/env bash
# Create a subject's active box and echo its id — the box where attestations
# live and that `revoke` receives from. Reusable CLI op over create_box.
#
# Usage: create-box.sh <registry-pkg> <registry-id> <subject-id>
set -euo pipefail
REGPKG=$1; REGISTRY=$2; SUBJECT=$3

out=$(sui client ptb \
    --move-call "$REGPKG::attestations::create_box" "@$REGISTRY" "@$SUBJECT" \
    --json)

# create_box claims exactly one Box (the active box); echo it.
box=$(echo "$out" | jq -r 'first(.objectChanges[] | select(.objectType | endswith("::Box")) | .objectId) // empty')
[ -n "$box" ] && { echo "$box"; exit 0; }
echo "create-box: no active box created" >&2; exit 1
