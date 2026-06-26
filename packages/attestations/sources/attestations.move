module attestations::attestations;

use std::internal::{Self, Permit};
use std::string::String;
use std::type_name;
use sui::derived_object;
use sui::display_registry::{Self, DisplayRegistry, Display, DisplayCap};
use sui::event;
use sui::transfer::Receiving;

#[error(code = 0)]
const ERevokeFromWrongBox: vector<u8> =
    b"Pass the subject's active Box to revoke, not its revoked one";

#[error(code = 1)]
const EFieldExists: vector<u8> =
    b"Display field already exists; add_display_field is append-only";

/// Shared singleton, parent UID for every per-subject `Box`.
public struct Registry has key {
    id: UID,
}

/// Derived-address key for one of a subject's two boxes. `revoked: false` keys
/// the active box, `revoked: true` the revoked box; both are claimed, shared
/// `Box` objects (siblings under the same `Registry`), so off-chain consumers
/// compute either address from `(registry_id, subject_id)`.
public struct BoxKey has copy, drop, store {
    subject: ID,
    revoked: bool,
}

/// Per-subject child of `Registry`. Each subject has two, both created by
/// `create_box`: the *active* box (`key.revoked == false`) and the *revoked*
/// box (`key.revoked == true`). An attestation lives in one of them via
/// transfer-to-object, and its status *is* which box owns it — an attestation
/// is revoked iff its owner box's `key.revoked` is true.
///
/// The Box stores its own `key` (so its address is recomputable, and an
/// attestation's status is readable from its owner) and its parent `registry`
/// id (so `revoke` can derive the sibling box's address).
public struct Box has key {
    id: UID,
    key: BoxKey,
    registry: ID,
}

/// Typed attestation about `subject`, stored as an object owned-by-Box via
/// transfer-to-object.
///
/// **Lifecycle invariant**: `key`-only (no `store`, no `drop`). No public
/// function returns one by value, so external callers can't transfer, wrap, or
/// drop it. Its only dispositions are `attest` (into the active box) and
/// `revoke` (from the active box to the revoked box); its status is which box
/// owns it, not a field here.
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    data: T,
}

/// Emitted when an `Attestation<T>` is added for `subject`.
public struct Attested<phantom T> has copy, drop {
    subject: ID,
}

/// Emitted when an `Attestation<T>` is revoked for `subject`.
public struct Revoked<phantom T> has copy, drop {
    subject: ID,
}

// === Setup ===

/// Create and share a subject's two `Box`es (active + revoked). Idempotent: a
/// no-op for either box that already exists.
public fun create_box(registry: &mut Registry, subject: ID) {
    let registry_id = object::id(registry);
    registry.claim_box(registry_id, BoxKey { subject, revoked: false });
    registry.claim_box(registry_id, BoxKey { subject, revoked: true });
}

// === Accessors ===

/// The subject this attestation is about.
public fun subject<T: store>(self: &Attestation<T>): ID { self.subject }

/// The typed payload.
public fun data<T: store>(self: &Attestation<T>): &T { &self.data }

/// Original-publish address of `T`'s defining package. Useful for on-chain
/// trust-list checks (e.g.
/// `assert!(trust_list.contains(attester_of<Audit>()))`).
public fun attester_of<T>(): address { type_name::original_id<T>() }

// === Attest / Revoke ===

/// Attest about `subject` with `data`. Gated by `Permit<T>`: only `T`'s
/// defining module can mint one, so authority to attest lives in that module —
/// uniform with `revoke` and `register_display`. The attestation goes to
/// `subject`'s *active* box address (`derive_address(registry, {subject,
/// false})`); the box need not exist yet — only `revoke` needs the `Box`
/// object. Returns the new attestation's `ID`, the one piece a schema can't
/// otherwise recover since the object goes straight to the box.
public fun attest<T: store>(
    registry: &Registry,
    _: Permit<T>,
    subject: ID,
    data: T,
    ctx: &mut TxContext,
): ID {
    let attestation = Attestation<T> { id: object::new(ctx), subject, data };
    let attestation_id = object::id(&attestation);
    let box_addr = derived_object::derive_address(
        object::id(registry),
        BoxKey { subject, revoked: false },
    );
    event::emit(Attested<T> { subject });
    transfer::transfer(attestation, box_addr);
    attestation_id
}

/// Revoke the attestation referenced by `rcv`: receive it from the active
/// `box` and move it to the subject's revoked box. Terminal — there is no
/// un-revoke. `rcv` alone identifies which attestation.
///
/// Gated by `Permit<T>`: only `T`'s defining module can mint one, so the
/// *policy* for who may revoke (a bearer cap, an admin cap, a multisig, …)
/// lives in that module, while the move and `Revoked<T>` event stay uniform
/// here — the same split as `register_display`.
public fun revoke<T: store>(
    box: &mut Box,
    _: Permit<T>,
    rcv: Receiving<Attestation<T>>,
) {
    assert!(!box.key.revoked, ERevokeFromWrongBox);
    let a = transfer::receive(&mut box.id, rcv);
    let subject = a.subject;
    let revoked_box = derived_object::derive_address(
        box.registry,
        BoxKey { subject, revoked: true },
    );
    event::emit(Revoked<T> { subject });
    transfer::transfer(a, revoked_box);
}

// === Display ===

/// Publish a `Display<Attestation<T>>` via the system display registry.
/// Authorized by `Permit<T>` (only `T`'s defining module can mint it);
/// one-per-T enforcement is provided by `display_registry`. The `DisplayCap` is
/// parked on the Registry so the schema can later append fields via
/// `add_display_field` (add-only).
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{data}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.description}`)
///
/// Revocation is not a Display field — it's which box owns the attestation.
/// Schemas adopting cross-cutting conventions (`expires_at`, etc. — see
/// CONVENTIONS.md) include those fields themselves.
public fun register_display<T: store>(
    registry: &Registry,
    display_registry: &mut DisplayRegistry,
    _: Permit<T>,
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
    transfer::public_transfer(cap, object::id(registry).to_address());
}

/// Append fields to an existing `Display<Attestation<T>>`. **Add-only**: aborts
/// `EFieldExists` if a field name is already set, so existing fields can't be
/// altered or removed. Gated by `Permit<T>` like `register_display`. `rcv`
/// receives the `DisplayCap` that `register_display` parked on the Registry
/// (found off-chain as the lone `DisplayCap<Attestation<T>>` the Registry owns).
public fun add_display_field<T: store>(
    registry: &mut Registry,
    display: &mut Display<Attestation<T>>,
    _: Permit<T>,
    rcv: Receiving<DisplayCap<Attestation<T>>>,
    fields: vector<String>,
    values: vector<String>,
) {
    let cap = transfer::public_receive(&mut registry.id, rcv);
    fields.zip_do!(values, |field, value| {
        assert!(!display.fields().contains(&field), EFieldExists);
        display.set(&cap, field, value);
    });
    transfer::public_transfer(cap, object::id(registry).to_address());
}

// === Internal ===

/// Create the `Registry` singleton at publish time.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx) });
}

/// Claim and share one box for `key`, or do nothing if it already exists (so
/// `create_box` is idempotent).
fun claim_box(registry: &mut Registry, registry_id: ID, key: BoxKey) {
    if (derived_object::exists(&registry.id, key)) return;
    let id = derived_object::claim(&mut registry.id, key);
    transfer::share_object(Box { id, key, registry: registry_id });
}

// === Test seam ===

/// Address of a subject's active (`revoked == false`) or revoked
/// (`revoked == true`) box. Tests use it to locate the two boxes; production
/// callers don't need it (off-chain consumers derive box addresses themselves,
/// and `BoxKey` is module-private so there's nothing to expose on-chain).
#[test_only]
public fun box_address(registry: &Registry, subject: ID, revoked: bool): address {
    derived_object::derive_address(object::id(registry), BoxKey { subject, revoked })
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun borrow_for_testing<T: store>(
    box: &mut Box,
    rcv: Receiving<Attestation<T>>,
): Attestation<T> {
    transfer::receive(&mut box.id, rcv)
}

#[test_only]
public fun put_back_for_testing<T: store>(box: &mut Box, a: Attestation<T>) {
    transfer::transfer(a, box.id.to_address());
}
