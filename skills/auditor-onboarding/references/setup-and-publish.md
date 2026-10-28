# Setup and publishing

Use Bash. Required tools: Git, a current `sui` CLI, `jq`, `curl`, and Python 3.11+
(for TOML parsing). Use the official [Sui installation guide](https://docs.sui.io/guides/developer/getting-started/sui-install)
and check installed command help before adapting commands to another CLI version.

## 1. Choose the workspace and wallet

Have the user choose an unused `WORKSPACE` directory. Clone the upstream repo:

```sh
set -euo pipefail
: "${WORKSPACE:?Set an absolute workspace path}"
mkdir -p "$WORKSPACE"
git clone https://github.com/MystenLabs/attestations.git "$WORKSPACE/attestations"
ATTESTATIONS_REPO="$WORKSPACE/attestations"
NETWORK=testnet
RECORDS="$WORKSPACE/records/$NETWORK"
mkdir -p "$RECORDS"
sui --version
```

Record the upstream revision and review it before copying code. Do not overwrite
an existing checkout. Create or clone the company's own repository at an
agreed `AUDITOR_REPO` path; creating a remote repository requires approval too.

If no wallet exists, ask the user to create one privately using their wallet or
`sui client` setup. A disposable testnet account is appropriate for learning.
Only collect its public address as `SENDER`. For custody, obtain the intended
multisig/custody address instead; the local CLI need not hold its private key.

Once the user's client is configured, inspect `sui client envs`. If testnet is
missing, add it with `sui client new-env --alias testnet --rpc
https://fullnode.testnet.sui.io:443`. Check the chain, not just the alias:

```sh
: "${SENDER:?Set the approved public publishing address}"
sui client --client.env "$NETWORK" chain-identifier
sui client --client.env "$NETWORK" balance "$SENDER"
```

Expected chain identifiers: testnet `4c78adac`, mainnet `35834a8a`. Stop if the
selected endpoint disagrees. Request testnet SUI at <https://faucet.sui.io/> for
this address and recheck its balance. Do not promise `sui client faucet` works
on testnet. Mainnet has no free faucet; obtain funding through the user's normal
process. Name registration later needs mainnet gas even during a testnet rehearsal.

## 2. Copy and customize the template

The company repository should contain a fresh package, for example:

```sh
: "${AUDITOR_REPO:?Set the absolute company repository path}"
SOURCE_PATH=packages/auditor
AUDITOR="$AUDITOR_REPO/$SOURCE_PATH"
test ! -e "$AUDITOR"
mkdir -p "$AUDITOR"
cp "$ATTESTATIONS_REPO/examples/auditor/Move.toml" "$AUDITOR/"
cp -R "$ATTESTATIONS_REPO/examples/auditor/sources" "$AUDITOR/"
cp -R "$ATTESTATIONS_REPO/examples/auditor/tests" "$AUDITOR/"
```

Do not copy generated builds or another deployment's `Published.toml`.
Before building:

- Rename `name` in Move.toml and all `auditor::` module/import references in
  **both source and tests**, for example to `acme_audits::`.
- Keep the `attestations = { r.mvr = "@mysten/attestations" }` dependency by
  default. This imports the core registry library; the auditor neither owns nor
  configures that name. Verify it below. Do not substitute a demo package.
- Set company-specific Display name and a real HTTPS icon or project URL.
  Preserve the standard description, link, link hash, and date conventions.
- Write the company's README with its audit policy, contact information, and
  report interpretation. MVR will use this source repository, not our template's.
- Retain authorization/revocation tests. Additional schema fields require their
  own review and tests. This onboarding does not require a schema redesign.
- Ignore `build/` and private operational files. Commit generated Move.lock and
  later Published.toml; do not edit lockfiles by hand.

## 3. Check the upstream dependency and Registry

`@mysten/attestations` belongs to the registry maintainers. It is unrelated to the
auditor's own MVR name. This check verifies the library the template compiles
against, not the auditor's naming permissions.

Read the reviewed upstream publication metadata for the selected network:

```sh
python3 - "$ATTESTATIONS_REPO" "$NETWORK" >"$RECORDS/core-publication.json" <<'PY'
import json, pathlib, sys, tomllib
root, network = sys.argv[1:]
publications = tomllib.loads((pathlib.Path(root) / 'packages/attestations/Published.toml').read_text())['published']
if network not in publications:
    raise SystemExit('STOP: no recorded core deployment for ' + network)
print(json.dumps(publications[network]))
PY
CORE_PKG=$(jq -er '.["published-at"]' "$RECORDS/core-publication.json")
CORE_ORIGINAL=$(jq -er '.["original-id"]' "$RECORDS/core-publication.json")
```

For the template's default MVR dependency, require resolution to match that
release. If lookup fails or differs, stop this dependency route and ask the
registry maintainers to repair it or supply the pinned alternative below. Do
not ask the auditor to register or modify `@mysten/attestations`.

```sh
MVR_API="https://$NETWORK.mvr.mystenlabs.com"
curl -fsS "$MVR_API/v1/resolution/@mysten/attestations" >"$RECORDS/core-resolution.json"
jq -e --arg expected "$CORE_PKG" '.package_id == $expected' "$RECORDS/core-resolution.json"
```

After upgrades, the package called and the original package defining
Registry/Attestation types can differ. Find the Registry in the original
package's publication transaction, then verify its current type and ownership:

```sh
sui client --client.env "$NETWORK" object "$CORE_ORIGINAL" --json >"$RECORDS/core-package.json"
CORE_PUBLISH_TX=$(jq -er '.prevTx' "$RECORDS/core-package.json")
sui client --client.env "$NETWORK" tx-block "$CORE_PUBLISH_TX" --json >"$RECORDS/core-publish.json"
jq -e '.effects.status.status == "success"' "$RECORDS/core-publish.json"
REGISTRY=$(jq -er --arg type "$CORE_ORIGINAL::attestations::Registry" '
  [.objectChanges[] | select(.type == "created" and .objectType == $type)] |
  select(length == 1) | .[0].objectId
' "$RECORDS/core-publish.json")
sui client --client.env "$NETWORK" object "$REGISTRY" --json >"$RECORDS/core-registry.json"
jq -e --arg type "$CORE_ORIGINAL::attestations::Registry" '
  .objType == $type and .owner.Shared != null
' "$RECORDS/core-registry.json"
```

If historical transaction data is unavailable or multiple Registries exist,
stop and obtain the intended Registry from a verified maintainer release record.

A missing core deployment is different from a missing name binding. If the
selected network has no verified deployment, stop and request a maintainer
release. Never publish another core or reuse testnet IDs.

### Maintainer-supplied alternative when the core name is unavailable

A deployed core can be used before its MVR binding is ready. Only with a
maintainer-verified release and the user's approval, replace the template's
`attestations` dependency with the supplied pinned source configuration. For
example, replace the SHA placeholder in this entry with the reviewed full commit:

```toml
attestations = { git = "https://github.com/MystenLabs/attestations.git", subdir = "packages/attestations", rev = "<MAINTAINER_VERIFIED_FULL_COMMIT_SHA>" }
```

The revision must include the core's generated publication metadata for the
selected network and source matching its deployed bytecode. A pinned local
checkout with those same records is also supported; preserve its revision and
make the dependency reproducible for source verification. Do not use a moving
branch or replace source verification with an unverified address.

Re-pin only the selected environment with
`sui move update-deps --environment "$NETWORK" --path "$AUDITOR"`. Review the
generated lockfile and preserve other environments. Continue the Registry checks
above, tests, and the publish simulation below. Require the simulated publish to
link the same `CORE_PKG`; the alternative bypasses name lookup, not identity or
bytecode verification. Record which dependency route was approved.

## 4. Test, simulate, then request publishing approval

```sh
(cd "$AUDITOR" && sui move test --build-env "$NETWORK" --lint --warnings-are-errors)
sui client --client.env "$NETWORK" publish "$AUDITOR" --sender "$SENDER" \
  --dry-run --json >"$RECORDS/publish-dry-run.json" 2>"$RECORDS/publish-dry-run.log"
jq -e --arg core "$CORE_PKG" '
  .effects.status.status == "success" and
  any(.input.transaction.transactions[]; (.Publish? // []) | index($core) != null)
' "$RECORDS/publish-dry-run.json"
```

Review costs, dependency IDs, source diff, and sender with the user. Do not bypass
verification with `--skip-dependency-verification`. `publish` selects the build
environment from the network; do not add `--build-env` to that command.

After review, use `--serialize-unsigned-transaction` in place of `--dry-run`,
with an explicit gas coin/budget as described in
[signing and custody](signing-and-custody.md). Both local and external signers
must inspect, simulate, and sign those saved bytes. Execute only after approval;
save the confirmed result as `publish.json` and stderr as `publish.log`.
Never retry a timeout without checking the approved transaction digest.

```sh
jq -e '.effects.status.status == "success"' "$RECORDS/publish.json"
AUDITOR_PKG=$(jq -er 'first(.objectChanges[] | select(.type == "published") | .packageId)' "$RECORDS/publish.json")
ADMIN_CAP=$(jq -er 'first(.objectChanges[] | select(.type == "created" and (.objectType | endswith("::audit::AuditAdminCap"))) | .objectId)' "$RECORDS/publish.json")
UPGRADE_CAP=$(jq -er 'first(.objectChanges[] | select(.type == "created" and (.objectType | endswith("::package::UpgradeCap"))) | .objectId)' "$RECORDS/publish.json")
```

Record the digest, these IDs, their owners, and the original package ID (equal
to `AUDITOR_PKG` on a fresh publish). With external signing, check whether the
CLI persisted publication metadata; if not, stop and reconcile Published.toml
with the confirmed transaction and captured build settings using the toolchain's
documented format. Preserve any other network's entries. Do not invent a recovery
command or republish to obtain a missing local file. Verify source with
`sui client --client.env "$NETWORK" verify-source "$AUDITOR"`. Commit the
verified publication metadata and push the exact source before MVR setup.
Reformatting Move source after publication can change compiled abort metadata.

## 5. Register Display

Review every template first. Registration is one-shot for this type and existing
fields cannot be replaced. Simulate with a funded sender on the same network:

```sh
sui client --client.env "$NETWORK" ptb --sender "@$SENDER" \
  --move-call "$AUDITOR_PKG::audit::register_audit_display" "@$REGISTRY" @0xd \
  --dry-run
```

Use the saved-byte signing flow after review and approval. Record its confirmed
digest and effects.
If already registered, inspect it instead of retrying. Verify actual rendered
fields after issuance; registering the templates alone does not prove rendering.

For mainnet, repeat from the deployment checks with `NETWORK=mainnet` and a new
records directory. Preserve both environments in the package's generated
publication files. No core mainnet release means **stop**, not bypass verification.
