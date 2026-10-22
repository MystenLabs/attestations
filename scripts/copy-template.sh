#!/usr/bin/env bash
# Copy examples/auditor to <dest>, with its registry dependency pointed at this
# checkout's packages/attestations.
#
# The template depends on the registry by its MVR name, which resolves to the
# package published on testnet. Built in place, it is therefore tested against
# that release rather than against the registry in this checkout, and a registry
# change that breaks the template would go unnoticed until the next publish.
# check-template.sh and the e2e walkthrough build this copy instead.
#
# Usage: bash scripts/copy-template.sh <dest-dir>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/examples/auditor"
dest="${1:?usage: copy-template.sh <dest-dir>}"

if [[ -e "$dest" ]]; then
    echo "copy-template: $dest already exists" >&2
    exit 1
fi

mvr_dep='attestations = { r.mvr = "@mysten/attestations" }'
local_dep="attestations = { local = \"$REPO_ROOT/packages/attestations\" }"

cp -R "$TEMPLATE" "$dest"
# The lock pins the MVR-resolved registry; let the copy resolve its own.
rm -rf "$dest/build" "$dest/Move.lock"

if ! awk -v from="$mvr_dep" -v to="$local_dep" \
        '$0 == from { print to; found = 1; next } { print } END { exit !found }' \
        "$TEMPLATE/Move.toml" >"$dest/Move.toml"; then
    echo "copy-template: examples/auditor/Move.toml no longer has the line" >&2
    echo "    $mvr_dep" >&2
    echo "  so this script can't repoint it; update mvr_dep above to match." >&2
    exit 1
fi
