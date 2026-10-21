/// Subjects are identifiable by their ID.
///
/// A derived address is used for each subject to store / revoke attestations.
module attestations::attestations;

use std::string::String;
use sui::clock::Clock;
use sui::derived_object;
use sui::display_registry::{Self, Display, DisplayRegistry, DisplayCap};
use sui::event;
use sui::table::{Self, Table};
use sui::transfer::Receiving;

#[error(code = 0)]
const EFieldExists: vector<u8> = b"Display field already exists; add_display_field is append-only";

#[error(code = 1)]
const EAlreadyRevoked: vector<u8> = b"Attestation is already revoked; revocation is terminal";

/// Derivation root attestations access.
public struct Registry has key {
    id: UID,
    anchors: Table<ID, UID>,
}

/// A single Attestation wrapper.
/// T stands for attestation data, eg `Audit { name: String, url: String }`.
public struct Attestation<T: store> has key {
    id: UID,
    data: T,
    subject: ID,
    created_at_ms: u64,
    revoked_at_ms: Option<u64>,
}

/// Emitted when an `Attestation<T>` is added for `subject`.
public struct Attested<phantom T> has copy, drop {
    subject: ID,
}

/// Emitted when an `Attestation<T>` is revoked for `subject`.
public struct Revoked<phantom T> has copy, drop {
    subject: ID,
}

public fun attest<T: store>(
    r: &Registry,
    _: internal::Permit<T>,
    subject: ID,
    data: T,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    event::emit(Attested<T> { subject });
    transfer::transfer(
        Attestation {
            id: object::new(ctx),
            data,
            subject,
            created_at_ms: clock.timestamp_ms(),
            revoked_at_ms: option::none(),
        },
        derived_object::derive_address(r.id.to_inner(), subject),
    );
}

/// Revoke an attestation from the registry.
public fun revoke<T: store>(
    r: &mut Registry,
    _: internal::Permit<T>,
    subject: ID,
    attestation: Receiving<Attestation<T>>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // If anchor hasn't yet been created, create on request.
    if (!r.anchors.contains(subject)) {
        r.anchors.add(subject, derived_object::claim(&mut r.id, subject));
    };

    let mut attestation = transfer::receive(&mut r.anchors[subject], attestation);
    assert!(subject == attestation.subject);
    assert!(attestation.revoked_at_ms.is_none(), EAlreadyRevoked);
    attestation.revoked_at_ms.fill(clock.timestamp_ms());
    event::emit(Revoked<T> { subject });
    transfer::transfer(attestation, derived_object::derive_address(r.id.to_inner(), subject));
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

// === Test seam ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun subject<T: store>(self: &Attestation<T>): ID { self.subject }

#[test_only]
public fun data<T: store>(self: &Attestation<T>): &T { &self.data }

#[test_only]
public fun created_at_ms<T: store>(self: &Attestation<T>): u64 { self.created_at_ms }

#[test_only]
public fun revoked_at_ms<T: store>(self: &Attestation<T>): Option<u64> { self.revoked_at_ms }

#[test_only]
public fun attested_subject<T>(self: &Attested<T>): ID { self.subject }

#[test_only]
public fun revoked_subject<T>(self: &Revoked<T>): ID { self.subject }
