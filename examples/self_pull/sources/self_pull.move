/// Example schema: a package author publishes a *negative* "self-pull" (recall)
/// attestation about their own package, authorized by presenting the package's
/// `UpgradeCap`.
///
/// A third authorization pattern alongside `audit_example`'s single admin cap
/// and `vuln_example`'s per-attestation bearer cap: here the authority is
/// *proof of control of the subject*. `attest_self_pull` derives the subject
/// from the cap (`package::upgrade_package`), so only the package's upgrade
/// authority can self-pull it — no registry-level primitive required.
module self_pull::self_pull;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use sui::package::{Self, UpgradeCap};
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};

#[error(code = 0)]
const EWrongPackage: vector<u8> =
    b"The UpgradeCap does not govern this box's subject";

/// Self-pull attestation payload. Defined here so self_pull is the
/// `Permit<SelfPull>` minting authority — the recorded attester for every
/// `Attestation<SelfPull>` is self_pull's published address.
public struct SelfPull has store, drop {
    /// Why the author is pulling the package (surfaced via `description`).
    reason: String,
}

/// One-shot setup: register the immutable `Display<Attestation<SelfPull>>`.
public fun register_self_pull_display(
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    attestation_registry::register_display<SelfPull>(
        display_registry,
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"polarity".to_string(),
        ],
        vector[
            b"Self-pull (author recall)".to_string(),
            b"{data.reason}".to_string(),
            b"negative".to_string(),
        ],
        std::internal::permit<SelfPull>(),
        ctx,
    );
}

/// Publish a self-pull about the package governed by `cap`. The subject is
/// `package::upgrade_package(cap)`, so only the holder of that package's
/// `UpgradeCap` can attest — authorization is proof of control of the subject.
/// Aborts `EBoxDoesNotExist` if the subject has no Box (call `create_box`
/// first). Returns the new attestation's id.
public fun attest_self_pull(
    registry: &Registry,
    cap: &UpgradeCap,
    reason: String,
    ctx: &mut TxContext,
): ID {
    attestation_registry::attest<SelfPull>(
        registry,
        package::upgrade_package(cap),
        SelfPull { reason },
        ctx,
    )
}

/// Rescind a self-pull, gated by the `UpgradeCap` of the box's subject — only
/// the package's own upgrade authority can. Aborts `EWrongPackage` if `cap`
/// governs a different package. Moves the attestation to the subject's revoked
/// sink (see `attestation_registry::revoke`).
public fun revoke_self_pull(
    cap: &UpgradeCap,
    box: &mut Box,
    rcv: Receiving<Attestation<SelfPull>>,
) {
    assert!(
        package::upgrade_package(cap) == attestation_registry::box_subject(box),
        EWrongPackage,
    );
    attestation_registry::revoke<SelfPull>(box, std::internal::permit<SelfPull>(), rcv);
}

/// The author's stated reason for the pull.
public fun reason(self: &SelfPull): &String { &self.reason }
