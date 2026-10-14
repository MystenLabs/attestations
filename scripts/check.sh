#!/usr/bin/env bash
# Lint, build, and test the Move packages, with an exit code you can trust.
#
# `sui move test` builds the package and runs its tests, so one command covers
# packages with tests and packages without. It also runs the extra linters, and
# any lint or compiler warning fails the package. Every package is attempted
# even if an earlier one fails, and the script exits nonzero if any failed.
#
# Usage:
#   bash scripts/check.sh                                   # every package but the template
#   bash scripts/check.sh packages/attestations             # just these
#
#   SUI=/path/to/sui bash scripts/check.sh                  # override the binary
#   BUILD_ENV=mainnet bash scripts/check.sh                 # override the build env

# Not `-e`: a failing package must not abort the run before the summary.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUI="${SUI:-sui}"
# These packages pin env-specific dependencies, so `sui move test` cannot pick a
# build env on its own. testnet is what demo/scripts/test-publish.sh publishes with.
BUILD_ENV="${BUILD_ENV:-testnet}"

pkgs=()
if (( $# )); then
    pkgs=("$@")
else
    # Not examples/auditor: it depends on the *published* registry by its MVR
    # name, so in place it can't build against registry changes that aren't
    # published yet. check-template.sh builds and tests it against this
    # checkout's registry instead. Name it explicitly to build it as published.
    # No `mapfile`: macOS ships bash 3.2, which lacks it.
    while IFS= read -r pkg; do
        pkgs+=("$pkg")
    done < <(cd "$REPO_ROOT" && find . -name Move.toml -not -path '*/build/*' \
        -not -path './examples/auditor/*' | sed 's|^\./||; s|/Move.toml$||' | sort)
fi

failed=()
for pkg in "${pkgs[@]}"; do
    if [[ ! -f "$REPO_ROOT/$pkg/Move.toml" ]]; then
        echo "✘ $pkg (no Move.toml)"
        failed+=("$pkg")
        continue
    fi

    out=$(mktemp)
    if (cd "$REPO_ROOT/$pkg" && "$SUI" move test --build-env "$BUILD_ENV" --lint --warnings-are-errors) >"$out" 2>&1; then
        # Surface the test tally when the package has one.
        echo "✔ $pkg $(grep -oE 'Total tests: [0-9]+; passed: [0-9]+' "$out" | tail -1)"
    else
        echo "✘ $pkg"
        sed 's/^/    /' "$out"
        failed+=("$pkg")
    fi
    rm -f "$out"
done

echo
if (( ${#failed[@]} )); then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "All ${#pkgs[@]} package(s) built and tested."
