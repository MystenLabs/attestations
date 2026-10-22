# Deploy the testnet demo auditor

Deploy `demo/attestations-demo-auditor` as a new package against the existing
registry. This runbook does not authorize deployment: obtain approval for the
release commit and publishing wallet before running the publish step.

The old demo and its attestations remain on-chain. This deployment does not
upgrade or migrate them. Do not publish this demonstration attester on mainnet
or add it to a mainnet trust list.

## 1. Verify the release

Use Bash from the repository root, with `sui`, `jq`, `curl`, and `python3` on
`PATH`. Start from the reviewed commit with no tracked changes. The local
registry dependency must match its deployed bytecode; do not edit that source.
All transaction commands below select testnet explicitly.

```sh
set -euo pipefail
DEMO=demo/attestations-demo-auditor
CORE=0x754da52dba4429dc141b4298c5afebb4697d7ff74a15580c0f3074f3f33f79e5
REGISTRY=0x333d2e0d4eba57451e942bfc1ebffd0d4daf599ff719bab556e2882109df4db3
OUT=$(mktemp -d "${TMPDIR:-/tmp}/attest-demo-release.XXXXXX")
SENDER=$(sui client --client.env testnet active-address)
printf 'Signer: %s\nRelease outputs: %s\n' "$SENDER" "$OUT"

sui client --client.env testnet chain-identifier  # hex: 4c78adac
sui client --client.env testnet balance
sui client --client.env testnet verify-source packages/attestations
bash scripts/check-format.sh
bash scripts/check.sh demo/attestations-demo-auditor
bash scripts/check-template.sh

sui client --client.env testnet publish "$DEMO" --dry-run --json \
  >"$OUT/dry-run.json" 2>"$OUT/dry-run.log"
jq -e --arg core "$CORE" '
  .effects.status.status == "success" and
  any(.input.transaction.transactions[]; (.Publish? // []) | index($core) != null)
' "$OUT/dry-run.json"
```

Stop if source verification fails, tests fail, or the dry-run does not link the
exact `CORE` above. Do not bypass dependency verification. Publish selects the
build environment from the target network; do not pass `--build-env` to it.
Review `effects.gasUsed` in the dry-run output and confirm the wallet has enough
testnet SUI. Keep the generated `Move.lock` committed, without hand-editing it.

## 2. Publish after approval

Publish only once. If a request times out, inspect the transaction and wallet
objects before retrying, to avoid creating another package and capabilities.

```sh
sui client --client.env testnet publish "$DEMO" --json \
  >"$OUT/publish.json" 2>"$OUT/publish.log"
jq -e '.effects.status.status == "success"' "$OUT/publish.json"
DEMO_PKG=$(jq -er 'first(.objectChanges[] | select(.type == "published") | .packageId)' "$OUT/publish.json")
ADMIN_CAP=$(jq -er 'first(.objectChanges[] | select(.type == "created" and (.objectType | endswith("::audit::AuditAdminCap"))) | .objectId)' "$OUT/publish.json")
UPGRADE_CAP=$(jq -er 'first(.objectChanges[] | select(.type == "created" and .objectType == "0x2::package::UpgradeCap") | .objectId)' "$OUT/publish.json")
printf 'Package: %s\nAuditAdminCap: %s\nUpgradeCap: %s\n' "$DEMO_PKG" "$ADMIN_CAP" "$UPGRADE_CAP"
sui client --client.env testnet verify-source "$DEMO"
```

Record these IDs and the publish digest in the release PR. Commit the generated
`Published.toml` and any tool-generated lockfile changes. Update this package's
README to show the deployment. Push that commit before linking its source in
MVR. Never move the old `attestations-demo-auditor/v1` tag to new code.

The publisher initially owns both capabilities. Confirm who will retain the
`AuditAdminCap` for demo issuance and who will custody the `UpgradeCap`. Create
MVR metadata before transferring the upgrade cap, or have its new custodian
sign the metadata transaction. Do not share either capability.

## 3. Register the demo Display

The shared system Display registry is `0xd`. The Display fields are append-only:
review the demo warning and project URL before registration. A second
registration for the same type aborts.

```sh
sui client --client.env testnet ptb \
  --move-call "$DEMO_PKG::audit::register_audit_display" "@$REGISTRY" @0xd \
  --json >"$OUT/display.json"
jq -e '.effects.status.status == "success"' "$OUT/display.json"
```

## 4. Create source metadata and update the demo name

Use a new testnet `PackageInfo`; the old one belongs to the old package and
cannot be retargeted. Set `SOURCE_REV` to the public commit from step 2, which
contains the new publication metadata and the exact deployed source.

```sh
SOURCE_REV=$(git rev-parse HEAD)
curl -fsS "https://raw.githubusercontent.com/MystenLabs/attestations/$SOURCE_REV/$DEMO/Published.toml" \
  >"$OUT/published-source.toml"
cmp "$DEMO/Published.toml" "$OUT/published-source.toml"
curl -fsS 'https://testnet.mvr.mystenlabs.com/v1/resolution/@mvr/metadata' \
  >"$OUT/metadata-package.json"
METADATA=$(jq -er '.package_id' "$OUT/metadata-package.json")

sui client --client.env testnet ptb \
  --move-call "$METADATA::package_info::new" "@$UPGRADE_CAP" --assign info \
  --move-call "$METADATA::git::new" \
    '"https://github.com/MystenLabs/attestations"' \
    '"demo/attestations-demo-auditor"' "\"$SOURCE_REV\"" --assign source \
  --move-call "$METADATA::package_info::set_git_versioning" info 1u64 source \
  --move-call "$METADATA::package_info::set_metadata" info '"default"' '"@pkg/attestations-demo-auditor"' \
  --move-call "$METADATA::package_info::transfer" info "@$SENDER" \
  --json >"$OUT/package-info.json"
jq -e '.effects.status.status == "success"' "$OUT/package-info.json"
PACKAGE_INFO=$(jq -er 'first(.objectChanges[] | select(.type == "created" and (.objectType | endswith("::package_info::PackageInfo"))) | .objectId)' "$OUT/package-info.json")
printf 'New testnet PackageInfo: %s\n' "$PACKAGE_INFO"
```

Have the **mainnet `AppCap` holder for `@pkg/attestations-demo-auditor`** update
that name's testnet mapping to `PACKAGE_INFO`, `DEMO_PKG`, and `UPGRADE_CAP`.
This is a different capability from the one for `@mysten/attestations`.
The holder needs mainnet gas even though the target is testnet.

The mapping update removes the old testnet network entry and adds the new one
in the same mainnet PTB (`move_registry::unset_network`, `app_info::new`, then
`move_registry::set_network`, using testnet chain identifier `4c78adac`). Leave
any mainnet binding unchanged. The UI may not list metadata owned by another
wallet; a PTB can supply these testnet IDs directly without transferring metadata.

After indexing, require `package_address` to equal `DEMO_PKG` and
`package_info.id` to equal `PACKAGE_INFO` at:

```text
https://testnet.mvr.mystenlabs.com/v1/names/@pkg/attestations-demo-auditor
```

The core's MVR name can be updated independently. Its old mapping does not
block this deployment or consumers configured with the new numeric IDs.

## 5. Issue and revoke examples

Use the new demo package itself as the subject. Do not issue example audits on
third-party packages without their approval. The link below is documentation,
not an audit report; `none` deliberately records no report digest.

This creates two example claims and revokes one. Run it once for the release
smoke test; rerunning creates additional permanent claims.

```sh
SUBJECT=$DEMO_PKG
REPORT_URL="https://github.com/MystenLabs/attestations/blob/$SOURCE_REV/$DEMO/README.md"
PUBLISHED_MS=$(python3 -c 'import time; print(time.time_ns() // 1000000)')
for state in live revoked; do
  sui client --client.env testnet ptb \
    --move-call "$DEMO_PKG::audit::attest_audit" \
      "@$ADMIN_CAP" "@$REGISTRY" "@$SUBJECT" \
      "\"DEMO ONLY - $state example; no security audit performed.\"" \
      "\"$REPORT_URL\"" none "$PUBLISHED_MS" @0x6 \
    --json >"$OUT/$state.json"
  jq -e '.effects.status.status == "success"' "$OUT/$state.json"
done
REVOKED_ID=$(jq -er 'first(.objectChanges[] | select(.type == "created" and (.objectType | contains("::attestations::Attestation<"))) | .objectId)' "$OUT/revoked.json")
sui client --client.env testnet ptb \
  --move-call "$DEMO_PKG::audit::revoke_audit" \
    "@$ADMIN_CAP" "@$REGISTRY" "@$SUBJECT" "@$REVOKED_ID" @0x6 \
  --json >"$OUT/revoke.json"
jq -e '.effects.status.status == "success"' "$OUT/revoke.json"
```

## 6. Verify the consumer

In the MVR repository, update the **testnet** entry in
`app/src/lib/attestation-config.json` (or the deployed
`NEXT_PUBLIC_ATTESTATION_CONFIG` override):

- `registryPkg`: `CORE` from step 1.
- `registryId`: `REGISTRY` from step 1.
- Add a trusted attester with `originalId: DEMO_PKG` and
  `name: "Demo auditor (not a security auditor)"`.
- Add `mvrName: "@pkg/attestations-demo-auditor"` only after its mapping is correct.
  Omit `iconUrl` to use the consumer's fallback avatar.

Replace the obsolete demo identity if present; preserve unrelated trusted
attesters and network entries. Do not add this demo under mainnet. A configured
environment override replaces the checked-in config, so inspect it before
redeploying the app.

Query `https://graphql.testnet.sui.io/graphql` for type
`CORE::attestations::Attestation<DEMO_PKG::audit::Audit>` using the query in
[the template guide](../../examples/auditor/README.md#listing-your-attestations).
After indexing, verify:

- The two smoke-test IDs exist with `subject` equal to `DEMO_PKG`.
- Both have the same owner, derived from `REGISTRY` and `SUBJECT`.
- The live claim has `revoked_at_ms: null`; the revoked claim has a timestamp.
- Both Displays render the demo name and warning, with no Display errors.
- `project_url` is the repository URL and `image_url` is absent.
- MVR's Security tab for the demo subject shows the live example as a demo claim
  and distinguishes the revoked example. Neither is presented as a real audit.

Keep the release outputs and verification results with the deployment record.
