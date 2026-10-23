# PackageInfo, SuiNS, and MVR

Continue with `NETWORK`, `RECORDS`, `AUDITOR_REPO`, `SOURCE_PATH`, `AUDITOR_PKG`,
and `UPGRADE_CAP` from setup. Collect the desired `MVR_NAME`, such as
`@acme/audits`, and confirm who controls each required object. Naming is optional
for issuance itself, but needed for the named-package browser walkthrough.

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
After approval, execute or use the [custody flow](signing-and-custody.md). Extract
the created `::package_info::PackageInfo` ID as `PACKAGE_INFO` and read it back:
its package address, upgrade-cap ID, source version/revision, and owner must match.
The `default` name enables reverse resolution only once the name points back to
this metadata. It does not reserve a name or grant trust.

## 2. Obtain the company's namespace on mainnet

Check whether the company already controls its SuiNS name. Ownership is not the
same as the address the name resolves to. A company controlling `acme.sui` can
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

- A new application needs authorization from the SuiNS owner and creates a
  mainnet `AppCap`. Record its ID and intended custodian.
- An existing application needs its AppCap owner. Do not attempt to recreate it
  or assume the publisher also owns the name.
- Prefer the supported UI for names held in kiosks or for subnames; their
  ownership/borrowing flows differ from a plain address-owned SuiNS object.
- Review metadata such as company description, icon, documentation, and contact.
- If a multisig/custody owner cannot sign through the UI, build a PTB from the
  documented contract calls and use the custody flow. Never move authority to
  a hot wallet merely to make a dropdown work.

### Testnet mapping: mainnet transaction, testnet IDs

Attach the **testnet** PackageInfo to the application, leaving any mainnet binding
unchanged. The contract accepts the testnet IDs as values; it cannot validate
that those objects exist on testnet, so verify them there first.

Resolve `@mvr/core` using the **mainnet** MVR API. Obtain and verify `MVR_REGISTRY`
from the official naming guide (not the attestation Registry). Set `APP_CAP` and
`APP_OWNER` from its mainnet object, and confirm the target record is the desired
name. For an initially absent testnet mapping, the documented PTB is:

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

This requires a **mainnet** PackageInfo for the mainnet auditor deployment. It is
not the `set_network` flow. After explicit confirmation of the package lineage,
simulate `move_registry::assign_package(registry, app_cap, package_info)` on
mainnet, then obtain separate approval for its permanent binding.

An existing mainnet binding cannot be replaced with a fresh package. Inspect it
and stop if it is unrelated. The AppCap and PackageInfo must be accessible to
the transaction sender; coordinate their owners rather than assuming a testnet
pointer-style update works on mainnet. Preserve the existing testnet mapping.

## 4. Verify after indexing

Read the selected network's API, retrying read-only queries for indexing delay:

```sh
curl -fsS "https://$NETWORK.mvr.mystenlabs.com/v1/names/$MVR_NAME" \
  >"$RECORDS/auditor-name.json"
jq -e --arg pkg "$AUDITOR_PKG" --arg info "$PACKAGE_INFO" '
  .package_address == $pkg and .package_info.id == $info
' "$RECORDS/auditor-name.json"
```

For this fresh deployment, require those exact IDs, source path/revision, and
version 1. Confirm any pre-existing other-network binding is unchanged. Record
capability owners and the successful transaction digest before continuing.

Sources: [PackageInfo management](https://docs.suins.io/move-registry/managing-package-info),
[maintainer practices](https://docs.suins.io/move-registry/maintainer-practices),
and [MVR contracts](https://github.com/MystenLabs/mvr/tree/main/packages).
