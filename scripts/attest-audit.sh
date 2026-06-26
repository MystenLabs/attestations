#!/usr/bin/env bash
# Issue an Attestation<Audit> about a subject and echo its id. Reusable CLI op
# over auditor::attest_audit (admin-cap-gated); the AuditAdminCap gates both
# attest and revoke. The subject's box need not exist yet (only revoke needs it).
#
# Usage: attest-audit.sh <audit-pkg> <admin-cap> <registry> <subject> <description> <report-url> <publish-date-ms>
set -euo pipefail
AUDITPKG=$1; CAP=$2; REGISTRY=$3; SUBJECT=$4; DESC=$5; URL=$6; PUBDATE=$7

sui client ptb \
    --move-call "$AUDITPKG::audit::attest_audit" "@$CAP" "@$REGISTRY" "@$SUBJECT" "\"$DESC\"" "\"$URL\"" "$PUBDATE" \
    --json \
  | jq -r 'first(.objectChanges[] | select(.objectType | contains("::Attestation<")) | .objectId)'
