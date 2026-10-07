#!/usr/bin/env bash
# Check, or fix, the formatting of every tracked Move file. `sui move format`
# runs prettier-move; the settings are in .prettierrc at the repo root.
#
# Usage:
#   bash scripts/check-format.sh           # exits nonzero if any file needs formatting
#   bash scripts/check-format.sh --write   # reformat in place
#
#   SUI=/path/to/sui bash scripts/check-format.sh   # override the binary
#
# Needs prettier-move: npm i -g prettier @mysten/prettier-plugin-move

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUI="${SUI:-sui}"

mode=--check
if [[ "${1:-}" == --write ]]; then
    mode=--write
fi

cd "$REPO_ROOT"
# Tracked files only, so the upgrade modules that test-publish.sh stages into
# sources/ for a moment are never picked up. No `mapfile`: macOS ships bash 3.2.
files=()
while IFS= read -r file; do
    files+=("$file")
done < <(git ls-files '*.move')

"$SUI" move format "$mode" "${files[@]}"
