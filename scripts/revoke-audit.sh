#!/usr/bin/env bash
# Revoke an Attestation<Audit> — stamps its revoked_at_ms; it stays at the
# subject's address. Reusable CLI op over auditor::revoke_audit; the
# attestation id is passed with `@` and resolves as the
# `Receiving<Attestation<Audit>>` arg.
#
# Usage: revoke-audit.sh <audit-pkg> <admin-cap> <registry> <subject> <attestation-id>
set -euo pipefail
AUDITPKG=$1; CAP=$2; REGISTRY=$3; SUBJECT=$4; ATTESTATION=$5

sui client ptb \
    --move-call "$AUDITPKG::audit::revoke_audit" "@$CAP" "@$REGISTRY" "@$SUBJECT" "@$ATTESTATION" @0x6 \
    >/dev/null
