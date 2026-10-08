#!/usr/bin/env bash
# Keep examples/auditor, the template new auditors copy, in step with the repo:
#
#   1. It lints, builds, and passes its tests against this checkout's registry,
#      not just the published one (see copy-template.sh for why that needs a copy).
#   2. The demo's auditor packages are still copies of it, apart from their
#      module name and the customizations listed in undo_customizations below.
#
# Usage:
#   bash scripts/check-template.sh
#
#   SUI=/path/to/sui bash scripts/check-template.sh     # override the binary
#   BUILD_ENV=mainnet bash scripts/check-template.sh    # override the build env

# Not `-e`: every check runs, and the exit status reports whether any failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUI="${SUI:-sui}"
BUILD_ENV="${BUILD_ENV:-testnet}"
TEMPLATE_SRC="$REPO_ROOT/examples/auditor/sources/audit.move"

work="$(mktemp -d "${TMPDIR:-/tmp}/attest-template-XXXXXX")"
trap 'rm -rf "$work"' EXIT

failed=0

# --- 1. The template against this checkout's registry ---

if bash "$REPO_ROOT/scripts/copy-template.sh" "$work/auditor"; then
    out="$work/test.log"
    if (cd "$work/auditor" &&
        "$SUI" move test --build-env "$BUILD_ENV" --lint --warnings-are-errors) >"$out" 2>&1; then
        echo "✔ examples/auditor against this checkout's registry" \
            "$(grep -oE 'Total tests: [0-9]+; passed: [0-9]+' "$out" | tail -1)"
    else
        echo "✘ examples/auditor against this checkout's registry"
        sed 's/^/    /' "$out"
        failed=1
    fi
else
    failed=1
fi

# --- 2. The demo's copies of the template ---

# Reads demo copy $1 on stdin and undoes its intentional differences from the
# template, so whatever is left must match the template exactly.
undo_customizations() {
    case "$1" in
        auditor_c)
            # Made by following the template's onboarding guide, which has the
            # auditor brand its Display.
            sed -e 's|b"Auditor C audit"|b"Audit attestation"|' \
                -e 's|b"https://raw.githubusercontent.com/MystenLabs/attestations/demo-latest/demo/auditor_c/icon.svg"|b"https://example.com/auditor-icon.svg"|'
            ;;
        *)
            cat
            ;;
    esac
}

for copy in auditor_a auditor_b auditor_c; do
    copy_src="$REPO_ROOT/demo/$copy/sources/audit.move"
    if diff -u --label "examples/auditor/sources/audit.move" \
            --label "demo/$copy/sources/audit.move (normalized)" \
            "$TEMPLATE_SRC" \
            <(sed "s/^module $copy::/module auditor::/" "$copy_src" | undo_customizations "$copy") \
            >"$work/drift.diff"; then
        echo "✔ demo/$copy matches examples/auditor"
    else
        echo "✘ demo/$copy has drifted from examples/auditor:"
        sed 's/^/    /' "$work/drift.diff"
        failed=1
    fi
done

exit "$failed"
