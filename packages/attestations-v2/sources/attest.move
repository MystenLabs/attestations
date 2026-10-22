/// Packages are identifiable by their ID.
///
/// A derived address is used for each package to store / revoke attestations.
///
/// 1 Registry
/// 1 Anchor per package
/// X attestations per package
///
///
/// Input: Package ID
/// - derive(Registry root, ID) -> where you look
/// - getOwnedObjects(res0)
module attestations::attestations;

use sui::clock::Clock;
use sui::derived_object;
use sui::table::{Self, Table};
use sui::transfer::Receiving;

/// Derivation root attestations access.
public struct Registry has key {
    id: UID,
    anchors: Table<ID, UID>,
}

/// A single Attestation wrapper.
/// T stands for attestation data, eg `Audit { name: String, url: String }`.
public struct Attestation<T: store> has key {
    id: UID,
    inner: T,
    package: ID,
    created_at_ms: u64,
    revoked_at_ms: Option<u64>,
}

public fun attest<T: store>(
    r: &Registry,
    package: ID,
    inner: T,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    transfer::transfer(
        Attestation {
            id: object::new(ctx),
            inner,
            package,
            created_at_ms: clock.timestamp_ms(),
            revoked_at_ms: option::none(),
        },
        derived_object::derive_address(r.id.to_inner(), package),
    );
}

/// Revoke an attestation from the registry.
public fun revoke<T: store>(
    r: &mut Registry,
    _: internal::Permit<T>,
    package: ID,
    attestation: Receiving<Attestation<T>>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // If anchor hasn't yet been created, create on request.
    if (!r.anchors.contains(package)) {
        r.anchors.add(package, derived_object::claim(&mut r.id, package));
    };

    let mut attestation = transfer::receive(&mut r.anchors[package], attestation);
    assert!(package == attestation.package);
    attestation.revoked_at_ms.fill(clock.timestamp_ms());
    transfer::transfer(attestation, derived_object::derive_address(r.id.to_inner(), package));
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry {
        id: object::new(ctx),
        anchors: table::new(ctx),
    });
}
