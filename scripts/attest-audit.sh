#!/usr/bin/env bash
# Issue an Attestation<Audit> about a subject and echo its id. Reusable CLI op
# over auditor::attest_audit (admin-cap-gated); the AuditAdminCap gates both
# attest and revoke. No setup is needed for a new subject.
# <registry> is the shared Registry object id. [report-hash] is the report's
# digest for the link_hash convention (e.g. sha256:…); omit it to record none.
#
# Usage: attest-audit.sh <audit-pkg> <admin-cap> <registry> <subject> <description> <report-url> <published-at-ms> [report-hash]
set -euo pipefail
AUDITPKG=$1; CAP=$2; REGISTRY=$3; SUBJECT=$4; DESC=$5; URL=$6; PUBDATE=$7; HASH=${8:-}

if [[ -n "$HASH" ]]; then
    HASH_ARG="some(\"$HASH\")"
else
    HASH_ARG=none
fi

sui client ptb \
    --move-call "$AUDITPKG::audit::attest_audit" "@$CAP" "@$REGISTRY" "@$SUBJECT" "\"$DESC\"" "\"$URL\"" "$HASH_ARG" "$PUBDATE" @0x6 \
    --json \
  | jq -r 'first(.objectChanges[] | select(.objectType | contains("::Attestation<")) | .objectId)'
