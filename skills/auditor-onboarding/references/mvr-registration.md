# PackageInfo, SuiNS, and MVR

Continue with `NETWORK`, `RECORDS`, `AUDITOR_REPO`, `SOURCE_PATH`, `AUDITOR_PKG`,
and `UPGRADE_CAP` from setup. Collect the desired `MVR_NAME`, such as
`@acme/audits` or `@pkg/acme-audits`, and confirm who controls each required object.
This is the auditor's name, not the upstream `@mysten/attestations` dependency.
Naming is optional for issuance itself, but needed for the named-package browser
walkthrough.

For mainnet, choose the custody path in section 3 before creating PackageInfo.
If combining creation and binding, complete the source/owner checks below but
use the combined PTB instead of the standalone creation PTB. Register the
application first if it has no AppCap yet; never run both creation recipes.

## 1. Create PackageInfo on the auditor package's network

Create one PackageInfo for this deployment, not one per audit. A fresh package
identity needs new metadata; the old PackageInfo cannot be retargeted. Upgrades
within a package lineage normally add a source entry for each new version.

First commit and push the company's source, tests, manifest, lockfile, README,
and publication metadata. Set `SOURCE_REPO` to its public repository URL and
`SOURCE_REV` to the immutable full commit SHA. Verify that exact revision is
publicly retrievable and reproduces the published bytecode. Never move an old
release tag to new source.

Set `INFO_SENDER` to the current UpgradeCap owner and `INFO_OWNER` to the approved
PackageInfo recipient. They may be the same address. Verify the cap on-chain:

```sh
sui client --client.env "$NETWORK" object "$UPGRADE_CAP" --json
curl -fsS "https://$NETWORK.mvr.mystenlabs.com/v1/resolution/@mvr/metadata" \
  >"$RECORDS/metadata-resolution.json"
METADATA=$(jq -er '.package_id' "$RECORDS/metadata-resolution.json")
```

Resolve and inspect the official metadata package before building. For a fresh
version-1 package, simulate this transaction:

```sh
REPO_ARG=$(jq -cn --arg text "$SOURCE_REPO" '$text')
PATH_ARG=$(jq -cn --arg text "$SOURCE_PATH" '$text')
REV_ARG=$(jq -cn --arg text "$SOURCE_REV" '$text')
NAME_ARG=$(jq -cn --arg text "$MVR_NAME" '$text')
sui client --client.env "$NETWORK" ptb --sender "@$INFO_SENDER" \
  --move-call "$METADATA::package_info::new" "@$UPGRADE_CAP" --assign info \
  --move-call "$METADATA::git::new" \
    "$REPO_ARG" "$PATH_ARG" "$REV_ARG" --assign source \
  --move-call "$METADATA::package_info::set_git_versioning" info 1u64 source \
  --move-call "$METADATA::package_info::set_metadata" info '"default"' "$NAME_ARG" \
  --move-call "$METADATA::package_info::transfer" info "@$INFO_OWNER" \
  --dry-run
```

For an existing deployment, inspect its version and metadata first; do not
blindly create duplicates or label a later version as version 1. Review the
variables as data, not shell expressions; never `eval` company-provided text.
After approval, follow [signing and custody](signing-and-custody.md). Extract
the created `::package_info::PackageInfo` ID as `PACKAGE_INFO` and read it back:
its package address, upgrade-cap ID, source version/revision, and owner must match.
The `default` name enables reverse resolution only once the name points back to
this metadata. It does not reserve a name or grant trust.

## 2. Choose a namespace on mainnet

Choose with the user before creating metadata:

- `@acme/audits`: a branded namespace controlled through `acme.sui`.
- `@pkg/acme-audits`: an available application name in MVR's public namespace.
  It requires mainnet gas and creates an AppCap for the chosen custodian, but
  does not require the auditor to buy or control a SuiNS name. Follow the public
  registration recipe in section 3 instead of purchasing a namespace.

For a branded namespace, check whether the company already controls its SuiNS
name. Ownership is not the same as the address the name resolves to. A company
controlling `acme.sui` can
register `@acme/audits`; it need not purchase a separate name for each network.

If necessary, open <https://suins.io/> with the user's mainnet wallet. Follow the
[SuiNS registration guide](https://docs.suins.io/user#register-names): check name
availability, price, and term; obtain approval before purchasing; then verify
ownership. Record renewal responsibility and expiry. Do not buy a guessed name.
A testnet-funded wallet alone cannot pay for this mainnet operation.

## 3. Register or update the MVR application

Use <https://www.moveregistry.com> and the official
[MVR naming guide](https://docs.suins.io/move-registry/mvr-names). In the app
management flow, select the company's namespace and desired package name.
Review the resulting `@company/package` string before signing. UI labels can
change; inspect the current page rather than assuming button names.

- A new application in a company namespace needs authorization from the SuiNS
  owner. Public `@pkg` registration uses the shared PublicName instead. Both
  create a mainnet `AppCap`; record its ID and intended custodian.
- An existing application needs its AppCap owner. Do not attempt to recreate it
  or assume the publisher also owns the name.
- Prefer the supported UI for names held in kiosks or for subnames; their
  ownership/borrowing flows differ from a plain address-owned SuiNS object.
- Review metadata such as company description, icon, documentation, and contact.
- If a multisig/custody owner cannot sign through the UI, build a PTB from the
  documented contract calls and use the custody flow. Never move authority to
  a hot wallet merely to make a dropdown work.

If an existing AppCap is inaccessible, do not overwrite the name or republish
the auditor package to recover it. Ask the owner to authorize the update, or
choose an available name with approval. Preserve the old record. If a custody
request is pending for the old choice, explicitly cancel/reconcile it first.

### Public `@pkg` registration

Check availability in the registry; an API error alone does not prove that a
name is free. Resolve `@mvr/public-names` and `@mvr/core` on mainnet. Obtain
`PUBLIC_NAME` (the shared `@pkg` PublicName) and `MVR_REGISTRY` from the official
[MVR deployment information](https://docs.suins.io/move-registry). Verify their
types/ownership and that the PublicName's underlying SuiNS registration is
`pkg.sui`. Do not create or take custody of the shared namespace itself.

Set `APP_SENDER` to the approved registration signer and `APP_OWNER` to the
intended AppCap recipient. Review the exact name and simulate:

```sh
curl -fsS https://mainnet.mvr.mystenlabs.com/v1/resolution/@mvr/public-names \
  >"$RECORDS/public-names-resolution.json"
PUBLIC_NAMES=$(jq -er '.package_id' "$RECORDS/public-names-resolution.json")
[[ "$MVR_NAME" == @pkg/* ]]
APP_NAME=${MVR_NAME#@pkg/}
test -n "$APP_NAME"
APP_NAME_ARG=$(jq -cn --arg text "$APP_NAME" '$text')
sui client --client.env mainnet ptb --sender "@$APP_SENDER" \
  --move-call "$PUBLIC_NAMES::public_names::create_app" \
    "@$PUBLIC_NAME" "@$MVR_REGISTRY" "$APP_NAME_ARG" @0x6 --assign cap \
  --transfer-objects '[cap]' "@$APP_OWNER" \
  --dry-run
```

Follow [signing and custody](signing-and-custody.md) after approval. Extract the
actual AppCap from execution and verify its name and owner before attaching
either network.
The [public-name contract](https://github.com/MystenLabs/mvr/blob/main/packages/public_names/sources/public_names.move)
defines this route; a public namespace is not a consumer trust endorsement.

### Testnet mapping: mainnet transaction, testnet IDs

Attach the **testnet** PackageInfo to the application, leaving any mainnet binding
unchanged. The contract accepts the testnet IDs as values; it cannot validate
that those objects exist on testnet, so verify them there first.

Resolve `@mvr/core` using the **mainnet** MVR API. Obtain and verify `MVR_REGISTRY`
from the official naming guide (not the attestation Registry). Set `APP_CAP` and
`APP_OWNER` from its mainnet object, and confirm the target record is the desired
name. Save the resolved package as `MVR_CORE`:

```sh
curl -fsS https://mainnet.mvr.mystenlabs.com/v1/resolution/@mvr/core \
  >"$RECORDS/mvr-core-resolution.json"
MVR_CORE=$(jq -er '.package_id' "$RECORDS/mvr-core-resolution.json")
```

For an initially absent testnet mapping, simulate:

```sh
sui client --client.env mainnet ptb --sender "@$APP_OWNER" \
  --move-call 0x1::option::some '<0x2::object::ID>' "@$PACKAGE_INFO" --assign info_id \
  --move-call 0x1::option::some '<address>' "@$AUDITOR_PKG" --assign package_address \
  --move-call 0x1::option::some '<0x2::object::ID>' "@$UPGRADE_CAP" --assign cap_id \
  --move-call "$MVR_CORE::app_info::new" info_id package_address cap_id --assign info \
  --move-call "$MVR_CORE::move_registry::set_network" \
    "@$MVR_REGISTRY" "@$APP_CAP" '"4c78adac"' info \
  --dry-run
```

If replacing an existing testnet mapping, add `move_registry::unset_network`
with the same registry, AppCap, and network string **immediately before
`set_network` in the same PTB**. Do not execute removal as a separate transaction.
Verify the network identifier against the actual testnet endpoint.

The UI may not list PackageInfo owned by another wallet. The AppCap holder can
supply verified testnet IDs directly via a PTB without transferring that metadata.

### Mainnet binding: permanent

This requires the **mainnet** auditor deployment and `NETWORK=mainnet`. Resolve
`METADATA` and `MVR_CORE` afresh on mainnet; do not carry over testnet metadata
package IDs. Verify the AppCap's current owner as `APP_OWNER` and the intended
package lineage. Inspect the existing binding: if already correct, verify it
instead of resubmitting; if unrelated, stop and choose another name.

`assign_package` permanently binds the name to one package lineage. It does not
make the Move package immutable or change its UpgradeCap policy. Compatible
upgrades remain possible under that policy, and testnet mappings remain separate.

For ordinary address-owned inputs, these operations require:

| Operation | Required owned inputs accessible to the sender |
| --- | --- |
| Create PackageInfo | UpgradeCap |
| Bind an existing mainnet PackageInfo | AppCap and PackageInfo |
| Create metadata and bind in one PTB | UpgradeCap and AppCap |
| Set a testnet mapping on mainnet | AppCap; the testnet IDs are values |

Shared protocol objects and gas are additional inputs. Sponsorship does not
satisfy ownership of the capabilities. Choose one path:

1. **Create and bind under a common owner.** If no PackageInfo exists and the
   UpgradeCap and AppCap already share an owner, replace section 1's creation
   PTB with this version-1 recipe. Set `INFO_OWNER` to the approved final
   metadata recipient; it need not be the current signer. Leave both capabilities
   with their current owner.

```sh
test "$NETWORK" = mainnet
REPO_ARG=$(jq -cn --arg text "$SOURCE_REPO" '$text')
PATH_ARG=$(jq -cn --arg text "$SOURCE_PATH" '$text')
REV_ARG=$(jq -cn --arg text "$SOURCE_REV" '$text')
NAME_ARG=$(jq -cn --arg text "$MVR_NAME" '$text')
sui client --client.env mainnet ptb --sender "@$APP_OWNER" \
  --move-call "$METADATA::package_info::new" "@$UPGRADE_CAP" --assign info \
  --move-call "$METADATA::git::new" \
    "$REPO_ARG" "$PATH_ARG" "$REV_ARG" --assign source \
  --move-call "$METADATA::package_info::set_git_versioning" info 1u64 source \
  --move-call "$METADATA::package_info::set_metadata" info '"default"' "$NAME_ARG" \
  --move-call "$MVR_CORE::move_registry::assign_package" \
    "@$MVR_REGISTRY" "@$APP_CAP" info \
  --move-call "$METADATA::package_info::transfer" info "@$INFO_OWNER" \
  --dry-run
```

2. **Keep UpgradeCap with a different owner.** Its owner runs section 1 with
   `INFO_OWNER` set to `APP_OWNER`. If PackageInfo already exists under another
   owner, that owner must approve and simulate its transfer first:

```sh
sui client --client.env mainnet ptb --sender "@$CURRENT_INFO_OWNER" \
  --move-call "$METADATA::package_info::transfer" "@$PACKAGE_INFO" "@$APP_OWNER" \
  --dry-run
```

After the approved creation/transfer executes, read back PackageInfo and require
its owner to equal the AppCap owner. That owner can then simulate binding without
access to the UpgradeCap:

```sh
sui client --client.env mainnet ptb --sender "@$APP_OWNER" \
  --move-call "$MVR_CORE::move_registry::assign_package" \
    "@$MVR_REGISTRY" "@$APP_CAP" "@$PACKAGE_INFO" \
  --dry-run
```

3. **Change UpgradeCap custody only if independently approved.** Verify the
   recipient's control, transfer only the requested cap, and read back ownership,
   package/version, and upgrade policy. Then use path 1 if metadata is absent,
   or use path 2 to make existing PackageInfo accessible to the AppCap owner.
   Do not transfer upgrade authority merely to avoid a metadata-transfer transaction.

Every execution follows [signing and custody](signing-and-custody.md) and needs
approval, including separate confirmation of the permanent binding. Preserve
existing testnet mappings, verify actual metadata/capability owners afterward,
and never record simulated object IDs as deployed.

### Change an existing default name

If a deployment switches to an approved alternative name, inspect its existing
PackageInfo rather than creating another one. `set_metadata` inserts a key; it
does not replace it. With `INFO_SENDER` set to the current PackageInfo owner and
`PACKAGE_INFO`/`METADATA` from its network, replace an existing `default` atomically:

```sh
NAME_ARG=$(jq -cn --arg text "$MVR_NAME" '$text')
sui client --client.env "$NETWORK" ptb --sender "@$INFO_SENDER" \
  --move-call "$METADATA::package_info::unset_metadata" "@$PACKAGE_INFO" '"default"' \
  --move-call "$METADATA::package_info::set_metadata" "@$PACKAGE_INFO" '"default"' "$NAME_ARG" \
  --dry-run
```

If the key is absent, use only `set_metadata`. Obtain approval and follow the
signing flow; do not execute removal separately. This changes reverse-name
metadata, not an existing permanent mainnet binding. Verify that the new name
points back to the same deployment.

## 4. Verify after indexing

Read the selected network's API, retrying read-only queries for indexing delay:

```sh
curl -fsS "https://$NETWORK.mvr.mystenlabs.com/v1/names/$MVR_NAME" \
  >"$RECORDS/auditor-name.json"
jq -e --arg pkg "$AUDITOR_PKG" --arg info "$PACKAGE_INFO" '
  .package_address == $pkg and .package_info.id == $info
' "$RECORDS/auditor-name.json"
```

For this fresh deployment, require those exact IDs, source path/revision, default
name, and version 1. Also verify forward and reverse resolution:

```sh
curl -fsS "https://$NETWORK.mvr.mystenlabs.com/v1/resolution/$MVR_NAME" \
  >"$RECORDS/auditor-resolution.json"
jq -e --arg pkg "$AUDITOR_PKG" '.package_id == $pkg' "$RECORDS/auditor-resolution.json"
REVERSE_QUERY=$(jq -cn --arg pkg "$AUDITOR_PKG" '{package_ids: [$pkg]}')
curl -fsS "https://$NETWORK.mvr.mystenlabs.com/v1/reverse-resolution/bulk" \
  -H 'Content-Type: application/json' --data "$REVERSE_QUERY" \
  >"$RECORDS/auditor-reverse.json"
jq -e --arg pkg "$AUDITOR_PKG" --arg name "$MVR_NAME" \
  '.resolution[$pkg].name == $name' "$RECORDS/auditor-reverse.json"
```

Confirm any pre-existing other-network binding is unchanged. Record capability
owners and the successful transaction digest before continuing.

Sources: [PackageInfo management](https://docs.suins.io/move-registry/managing-package-info),
[maintainer practices](https://docs.suins.io/move-registry/maintainer-practices),
and [MVR contracts](https://github.com/MystenLabs/mvr/tree/main/packages).
