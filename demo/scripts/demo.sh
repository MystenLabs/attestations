#!/usr/bin/env bash
# End-to-end demo, composed from the CLI ops in scripts/ (create-box,
# attest-audit, revoke-audit) plus a few inline `sui client ptb` calls — every
# on-chain action here is a plain CLI move-call a user could run by hand.
#
# Scenario (mirrors the scenario in demo/README.md):
#   - the dependency has two published versions (v1, v2); audit v1 (Audit, stays
#     active) and leave v2 (the latest) unaudited — so the Security page shows the
#     latest version as unaudited while an older version was audited
#   - create boxes for the dependency (v1) and the subject (which depends on it)
#   - audit the subject with AuditV2 (score 95; the live signal)
#   - audit the subject with v1 Audit (revoked at the end)
#   - an Audit from Auditor B (a second, untrusted auditor identity) + an
#     attest_internal_note on the subject (both filtered out by a trust consumer)
#   - Audits from Auditor C (a second trusted auditor) on the subject + dependency v1
#   - revoke the subject's v1 audit
#   - write demo-ids.json for the MVR seeder
#
# Requires: REGISTRY_ID env; packages test-published (Pub.localnet.toml); the
# active sui client address funded and holding the AuditAdminCap.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OPS="$REPO_ROOT/scripts"
RPC="${RPC:-http://127.0.0.1:9000}"
PUBFILE="${PUBFILE:-$REPO_ROOT/Pub.localnet.toml}"
REGISTRY="${REGISTRY_ID:?REGISTRY_ID is required (printed by test-publish.sh)}"

# Read a field (e.g. published-at) from the pubfile's [[published]] block for
# `<pkg>`. The pubfile is TOML-ish text we just scan per block — python is the
# simplest tool for that. (Same helper as demo/scripts/test-publish.sh.)
parse_pkg_field() {
    python3 - "$PUBFILE" "$1" "$2" <<'PY'
import re, sys
pubfile, target, field = sys.argv[1], sys.argv[2], sys.argv[3]
for block in open(pubfile).read().split('[[published]]'):
    if '/' + target in block:
        m = re.search(field + r'\s*=\s*"([^"]+)"', block)
        if m:
            print(m.group(1)); break
PY
}

REGPKG=$(parse_pkg_field attestations published-at)
AUDIT=$(parse_pkg_field auditor_a published-at)      # v2/latest id (has audit + audit_v2)
AUDIT_ORIG=$(parse_pkg_field auditor_a original-id)  # v1 id — defines Audit + AuditAdminCap
DEP_V1=$(parse_pkg_field dependency_example original-id)   # v1 id (audited)
DEP_V2=$(parse_pkg_field dependency_example published-at)  # v2 id (latest, unaudited)
SUBJ=$(parse_pkg_field subject_example published-at)
AUDITOR_B=$(parse_pkg_field auditor_b published-at)
AUDITOR_C=$(parse_pkg_field auditor_c published-at)

# The object id of the single `structtype` object owned by `addr`.
find_owned() {
    curl -s "$RPC" -H 'Content-Type: application/json' -d "{
      \"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"suix_getOwnedObjects\",
      \"params\":[\"$1\",{\"filter\":{\"StructType\":\"$2\"}}]}" \
      | jq -r '.result.data[0].data.objectId // empty'
}

# The AuditAdminCap was transferred to the publisher at publish; find it among
# the active address's owned objects.
ADDR=$(sui client active-address)
CAP=$(find_owned "$ADDR" "$AUDIT_ORIG::audit::AuditAdminCap")

echo "registry:    $REGISTRY"
echo "audit pkg:   $AUDIT (orig $AUDIT_ORIG)"
echo "admin cap:   $CAP"

# Fixed demo report publication date (ms), surfaced via the published_at
# convention. A real auditor passes the actual report date.
PUBDATE=1748736000000   # 2025-06-01

echo "▶ create boxes (dependency v1 + subject)"
DEP_BOX=$(bash "$OPS/create-box.sh" "$REGPKG" "$REGISTRY" "$DEP_V1")
SUBJ_BOX=$(bash "$OPS/create-box.sh" "$REGPKG" "$REGISTRY" "$SUBJ")
echo "  dependency v1 active box: $DEP_BOX"
echo "  subject active box:       $SUBJ_BOX"

echo "▶ attest_audit on dependency v1 (stays active; v2 the latest, left unaudited)"
DEP_AUDIT=$(bash "$OPS/attest-audit.sh" "$AUDIT" "$CAP" "$REGISTRY" "$DEP_V1" "Dependency audit — no findings" "https://audits.example.com/dependency-v1.pdf" "$PUBDATE")
echo "  $DEP_AUDIT"

echo "▶ attest_audit_v2 on subject (score 95, the live signal)"
SUBJ_AUDIT_V2=$(sui client ptb \
    --move-call "$AUDIT::audit_v2::attest_audit_v2" "@$CAP" "@$REGISTRY" "@$SUBJ" '"Subject audit (v2) — passed"' '"https://audits.example.com/subject-v1.pdf"' "$PUBDATE" 95 \
    --json \
  | jq -r 'first(.objectChanges[] | select(.objectType | contains("::AuditV2>")) | .objectId)')
echo "  $SUBJ_AUDIT_V2"

echo "▶ attest_audit on subject (v1, will be revoked)"
SUBJ_AUDIT_V1=$(bash "$OPS/attest-audit.sh" "$AUDIT" "$CAP" "$REGISTRY" "$SUBJ" "Subject audit (v1) — superseded" "https://audits.example.com/subject-v1.pdf" "$PUBDATE")
echo "  $SUBJ_AUDIT_V1"

echo "▶ Auditor B audit (untrusted identity) + attest_internal_note (both filtered out)"
# Auditor B is a second, identical auditor that simply isn't in the trust
# config — its Audit is filtered out by *identity*, not by type. Its
# AuditAdminCap is its own distinct type (auditor_b's id).
AUDITOR_B_CAP=$(find_owned "$ADDR" "$AUDITOR_B::audit::AuditAdminCap")
bash "$OPS/attest-audit.sh" "$AUDITOR_B" "$AUDITOR_B_CAP" "$REGISTRY" "$SUBJ" "Auditor B review" "https://auditor-b.example/r.pdf" "$PUBDATE" >/dev/null
sui client ptb \
    --move-call "$AUDIT::audit_v2::attest_internal_note" "@$REGISTRY" "@$SUBJ" '"no Display registered"' \
    >/dev/null

echo "▶ Auditor C audits (a second trusted auditor): subject + dependency v1"
AUDITOR_C_CAP=$(find_owned "$ADDR" "$AUDITOR_C::audit::AuditAdminCap")
bash "$OPS/attest-audit.sh" "$AUDITOR_C" "$AUDITOR_C_CAP" "$REGISTRY" "$SUBJ" "Subject audit — no critical findings" "https://auditor-c.example/subject.pdf" "$PUBDATE" >/dev/null
bash "$OPS/attest-audit.sh" "$AUDITOR_C" "$AUDITOR_C_CAP" "$REGISTRY" "$DEP_V1" "Dependency audit — clean" "https://auditor-c.example/dependency.pdf" "$PUBDATE" >/dev/null

echo "▶ revoke the subject's v1 audit (the dependency v1 audit stays active)"
bash "$OPS/revoke-audit.sh" "$AUDIT" "$CAP" "$SUBJ_BOX" "$SUBJ_AUDIT_V1"

# Hand-off for the MVR Postgres seeder. All values are object ids, so a plain
# interpolated heredoc is clearer than building the JSON with a tool.
DEMO_IDS="$REPO_ROOT/demo-ids.json"
cat > "$DEMO_IDS" <<EOF
{
  "registryId": "$REGISTRY",
  "attestationRegistryPkg": "$REGPKG",
  "subjects": {
    "subject": "$SUBJ",
    "dependency": "$DEP_V1"
  },
  "dependencyVersions": [
    { "version": 1, "address": "$DEP_V1" },
    { "version": 2, "address": "$DEP_V2" }
  ],
  "trustedAttestors": [
    {
      "name": "auditor_a",
      "originalId": "$AUDIT_ORIG",
      "latestId": "$AUDIT"
    },
    {
      "name": "auditor_c",
      "originalId": "$AUDITOR_C",
      "latestId": "$AUDITOR_C"
    }
  ],
  "untrustedAttestors": [
    {
      "name": "auditor_b",
      "id": "$AUDITOR_B"
    }
  ],
  "createdAttestations": {
    "dependencyAudit": "$DEP_AUDIT",
    "subjectAuditV2": "$SUBJ_AUDIT_V2"
  }
}
EOF
echo "▶ wrote $DEMO_IDS"
