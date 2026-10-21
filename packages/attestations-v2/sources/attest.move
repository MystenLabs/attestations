/// Packages are identifiable by their ID.
///
/// A derived address is used for each package to store / revoke attestations.
module attestations::attestations;

use std::string::String;
use sui::clock::Clock;
use sui::derived_object;
use sui::display_registry::{Self, Display, DisplayRegistry, DisplayCap};
use sui::table::{Self, Table};
use sui::transfer::Receiving;

#[error(code = 0)]
const EFieldExists: vector<u8> = b"Display field already exists; add_display_field is append-only";

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
    _: internal::Permit<T>,
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

public fun register_display<T: store>(
    registry: &Registry,
    display_registry: &mut DisplayRegistry,
    _: internal::Permit<T>,
    fields: vector<String>,
    values: vector<String>,
    ctx: &mut TxContext,
) {
    let (mut display, cap) = display_registry::new<Attestation<T>>(
        display_registry,
        internal::permit<Attestation<T>>(),
        ctx,
    );
    fields.zip_do!(values, |field, value| display.set(&cap, field, value));
    display.share();

    // Park the `DisplayCap` on the Registry. It's kept (not destroyed) so the
    // schema can later append fields via `add_display_field`, which receives
    // it, adds, and re-parks. No public path here exposes `set`-overwrite,
    // `unset`, or `clear`, so the Display is effectively append-only.
    transfer::public_transfer(cap, registry.id.to_address());
}

public fun add_display_field<T: store>(
    registry: &mut Registry,
    display: &mut Display<Attestation<T>>,
    _: internal::Permit<T>,
    rcv: Receiving<DisplayCap<Attestation<T>>>,
    fields: vector<String>,
    values: vector<String>,
) {
    let cap = transfer::public_receive(&mut registry.id, rcv);
    fields.zip_do!(values, |field, value| {
        assert!(!display.fields().contains(&field), EFieldExists);
        display.set(&cap, field, value);
    });
    transfer::public_transfer(cap, registry.id.to_address());
}
