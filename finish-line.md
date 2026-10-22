To finalize the attestations project, we need to do the following steps.


TODO:

- [ ] Publish the package to testnet
- [ ] Point `@mysten/attestations` at the new testnet package
  - The existing name is `@mysten/attestations`, not `@mvr/attestations`.
    Live MVR resolution currently returns testnet package
    `0x6e0e1141d77448253ab434b008a01259e81c5c31bd1cdac8922a5256da690c09`,
    with no mainnet package assigned. If we want `@mvr/attestations` instead,
    register it separately under the `mvr` namespace and update consumers;
    that is not a repoint of the existing name.
  - After publishing, use [Move Registry](https://www.moveregistry.com)'s
    metadata page to create a **new testnet `PackageInfo`** with the new
    package's `UpgradeCap`. The old `PackageInfo` cannot be retargeted to a
    different package. Do this before transferring the new cap to the multisig,
    or have the multisig authorize metadata creation afterward.
  - Add source metadata for the new package's version 1: repository
    `https://github.com/MystenLabs/attestations`, path `packages/attestations`,
    and a new immutable tag or commit matching the published source and its
    publication metadata. Do not reuse or move the old `testnet/v1` tag.
  - Connect the wallet holding the existing name's **mainnet `AppCap`**, open
    `@mysten/attestations` for editing, select the new **Testnet metadata**,
    and save. This transaction needs mainnet gas even though it changes the
    testnet target. It does not require transferring the SuiNS name or the old
    package's `UpgradeCap`.
  - The underlying mainnet PTB calls `@mvr/core::move_registry::unset_network`
    for the testnet chain identifier, then `set_network` with a new
    `@mvr/core::app_info::new` containing the new testnet `PackageInfo` ID,
    package address, and `UpgradeCap` ID. Keep removal and replacement in one
    transaction; the UI's update flow does this. Leave the mainnet binding alone.
  - After indexing, verify that this command returns the new package ID:
    ```sh
    curl -fsS 'https://testnet.mvr.mystenlabs.com/v1/resolution/@mysten/attestations'
    ```
    Check the source tag and path at
    `https://testnet.mvr.mystenlabs.com/v1/names/@mysten/attestations` too.
    Refresh the template dependency with
    `sui move update-deps --path examples/auditor --environment testnet`, then
    run `bash scripts/check.sh examples/auditor`. Review and commit the generated
    lockfile change; do not edit `Move.lock` by hand.
  - This changes name resolution only. Update consumers' package/type IDs and
    shared `Registry` ID separately. Existing attestations and deployed schema
    packages remain tied to the old deployment; the name change does not migrate
    them.
- [ ] Push into this repository the demo package that we can use for showing the attestations functionality on Move registry
- [ ] Deploy the demo package on testnet.
- [ ] Move the upgrade cap to the multisig that we have
- [ ] Update the move registry code and existing PRs with any latest changes from this repository
- [ ] Deploy a new move registry instance with the updated code and demo package
- [ ] Verify that the attestations functionality works as expected on the new move registry instance
- [ ] Create a SKILL that demonstrates the attestations functionality and how to use it, particularly around
how to deploy the template audit package, how to create attestations, and how to verify them that they nicely exist
on Move registry. This SKILL should be a step-by-step guide that can be followed by developers who want to use the attestations functionality in their own projects.
- [ ] Publish attestations package on mainnet
- [ ] Move upgradecap to the multisig
- [ ] Assign the mainnet package to `@mysten/attestations`
  - Create its mainnet `PackageInfo` using the new mainnet `UpgradeCap` (the
    multisig must authorize this if the cap has already been transferred).
    Select it as **Mainnet metadata** on the existing name and save using the
    name's mainnet `AppCap`.
  - Verify the package identity before signing: the mainnet binding is permanent
    and cannot later be redirected to an unrelated fresh publish. If a mainnet
    package has already been assigned by then, stop rather than trying to
    replace it. Adding this binding does not replace the separate testnet target.
- [ ] Ask asymptotic to use the skill and deploy one audit attestation on a mainnet package.
- [ ] If that one audit works fine, then we can ask asymptotic to deploy the rest of the audits on mainnet.
