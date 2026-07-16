#!/usr/bin/env bash
# Revoke an Attestation<Audit> — moves it from the active box to the revoked
# box. Reusable CLI op over auditor::revoke_audit; the attestation id is
# passed with `@` and resolves as the `Receiving<Attestation<Audit>>` arg.
#
# Usage: revoke-audit.sh <audit-pkg> <admin-cap> <active-box> <attestation-id>
set -euo pipefail
AUDITPKG=$1; CAP=$2; BOX=$3; ATTESTATION=$4

sui client ptb \
    --move-call "$AUDITPKG::audit::revoke_audit" "@$CAP" "@$BOX" "@$ATTESTATION" \
    >/dev/null
