module attestation_registry::attestation_registry;

use std::internal::Permit;
use std::string::String;
use std::type_name;
use sui::derived_object;
use sui::display_registry::{Self, DisplayRegistry};
use sui::event;
use sui::transfer::Receiving;

#[error(code = 0)]
const EBoxAlreadyExists: vector<u8> =
    b"A Box already exists for this subject";

#[error(code = 1)]
const EBoxDoesNotExist: vector<u8> =
    b"No Box exists for this subject; call create_box first";

/// Shared singleton, parent UID for every per-subject `Box`.
public struct Registry has key {
    id: UID,
}

/// Derived-address key for a subject's two boxes. `revoked: false` is the
/// active box (a claimed, shared `Box`); `revoked: true` is the revoked sink
/// — a bare address that revoked attestations are moved to and only ever read
/// off-chain. The two are siblings under the same `Registry`, so off-chain
/// consumers compute either from `(registry_id, subject_id)`.
public struct BoxKey has copy, drop, store {
    subject: ID,
    revoked: bool,
}

/// Per-subject child of `Registry`: the *active* box. Owns every un-revoked
/// attestation about its subject via transfer-to-object.
///
/// Its address is `derive_address(registry, BoxKey { subject, revoked: false })`,
/// computable off-chain from `(registry_id, subject_id)`. `revoke` *moves*
/// attestations out to the revoked sink, so enumerating this box yields exactly
/// the active set — no per-object status filter. `registry` is the parent id,
/// retained so `revoke` can derive the sink without a `&Registry` argument.
public struct Box has key {
    id: UID,
    subject: ID,
    registry: ID,
}

/// Typed attestation about `subject`. Stored as an object owned-by-Box via
/// transfer-to-object.
///
/// **Lifecycle invariant**: `key`-only (no `store`, no `drop`). External
/// callers have no way to obtain an `Attestation<T>` by value (no public
/// function returns one), and even if they did they couldn't transfer it
/// (`public_transfer` requires `store`), wrap it in another struct (Move
/// forbids storing `key` objects inside other objects), or drop it. Its only
/// dispositions are `attest` (into the active box) and `revoke` (out to the
/// revoked sink); revocation is encoded by *which* box owns it, not by a field.
public struct Attestation<T: store> has key {
    id: UID,
    subject: ID,
    data: T,
}

/// Emitted by every `attest` call. Indexers filter by the phantom `T`
/// (which becomes part of the event's fully-qualified Move type — RPC
/// supports filtering by struct-type) and key by `subject`.
public struct Attested<phantom T> has copy, drop {
    subject: ID,
}

/// Emitted by every `revoke` call. Same shape as `Attested` for symmetry.
public struct Revoked<phantom T> has copy, drop {
    subject: ID,
}

/// Frozen wrapper that locks a `DisplayCap<Attestation<T>>` so the Display
/// template registered by `register_display` is permanently immutable. The
/// `cap` field is module-private; freezing makes the wrapper itself
/// immovable and unsharable; together those make the cap permanently
/// inaccessible without the @0x0 transfer anti-pattern.
public struct DisplayLock<T: store> has key {
    id: UID,
    cap: display_registry::DisplayCap<Attestation<T>>,
}

// === Setup ===

/// Create the `Registry` singleton at publish time.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx) });
}

/// Create the per-subject active `Box`. Aborts `EBoxAlreadyExists` if one
/// already exists for this `subject`. The revoked sink is not claimed — it is
/// a bare address `revoke` transfers to (see `revoked_box_address`).
public fun create_box(registry: &mut Registry, subject: ID) {
    let registry_id = object::id(registry);
    let key = BoxKey { subject, revoked: false };
    assert!(!derived_object::exists(&registry.id, key), EBoxAlreadyExists);
    let id = derived_object::claim(&mut registry.id, key);
    transfer::share_object(Box { id, subject, registry: registry_id });
}

// === Accessors ===

/// The subject this attestation is about.
public fun subject<T: store>(self: &Attestation<T>): ID { self.subject }

/// The subject a `Box` holds attestations about. Lets a schema's `revoke_*`
/// wrapper check that its authority governs this box's subject before revoking
/// (e.g. an `UpgradeCap`-gated self-pull).
public fun box_subject(box: &Box): ID { box.subject }

/// The typed payload.
public fun data<T: store>(self: &Attestation<T>): &T { &self.data }

/// Original-publish address of `T`'s defining package. Useful for on-chain
/// trust-list checks (e.g.
/// `assert!(trust_list.contains(attester_of<Audit>()))`).
public fun attester_of<T>(): address { type_name::original_id<T>() }

/// Address of `subject`'s revoked sink under `registry`: where `revoke` moves
/// revoked attestations. Bare (never claimed) — revocation is terminal, so the
/// sink is only ever read off-chain via `getOwnedObjects`. Off-chain consumers
/// compute the same address from `(registry_id, subject_id)`.
public fun revoked_box_address(registry: &Registry, subject: ID): address {
    revoked_address(object::id(registry), subject)
}

/// Shared derivation of the revoked-sink address from the parent `registry`
/// id, so `revoke` (which holds only the id) and `revoked_box_address` (which
/// holds a `&Registry`) can't drift in how they salt the key.
fun revoked_address(registry: ID, subject: ID): address {
    derived_object::derive_address(registry, BoxKey { subject, revoked: true })
}

// === Attest / Revoke ===

/// Attest about `subject` (under `registry`) with `data`. The caller must
/// produce a `T` value, which Move's construction rules already restrict to
/// `T`'s defining package — that's the property `attester_of<T>()` records.
/// Aborts `EBoxDoesNotExist` if no Box exists for this subject (call
/// `create_box` first). Returns the new attestation's `ID`, the one piece a
/// schema can't otherwise recover (the object goes straight to the Box), so
/// it can build whatever revocation authority it wants — a bearer cap bound
/// to this id, an admin-gated revoke, or none at all.
public fun attest<T: store>(
    registry: &Registry,
    subject: ID,
    data: T,
    ctx: &mut TxContext,
): ID {
    let key = BoxKey { subject, revoked: false };
    assert!(derived_object::exists(&registry.id, key), EBoxDoesNotExist);
    let box_addr = derived_object::derive_address(object::id(registry), key);
    let attestation = Attestation<T> {
        id: object::new(ctx),
        subject,
        data,
    };
    let attestation_id = object::id(&attestation);
    event::emit(Attested<T> { subject });
    transfer::transfer(attestation, box_addr);
    attestation_id
}

/// Revoke the attestation referenced by `rcv`: receive it from its active
/// `box` and move it to the subject's revoked sink (see `revoked_box_address`),
/// where it stays readable off-chain but out of the active set. Terminal —
/// there is no un-revoke. `rcv` alone identifies which attestation.
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
    let a = transfer::receive(&mut box.id, rcv);
    let subject = a.subject;
    event::emit(Revoked<T> { subject });
    transfer::transfer(a, revoked_address(box.registry, subject));
}

// === Display ===

/// Publish an immutable `Display<Attestation<T>>` via the system display
/// registry. Authorized by `Permit<T>` (only `T`'s defining module can mint
/// it); one-per-T enforcement is provided by `display_registry`.
///
/// Template strings in `values` reference fields of `Attestation<T>`:
/// - Top-level: `{subject}`, `{data}`
/// - T's own fields are under `{data.<field>}` (e.g. `{data.score}`)
///
/// Revocation is not a Display field — it's encoded by which box owns the
/// attestation. Schemas adopting cross-cutting conventions (`expires_at`,
/// `requires`, etc. — see CONVENTIONS.md) include those fields themselves.
#[allow(lint(freeze_wrapped))]
public fun register_display<T: store>(
    display_registry: &mut DisplayRegistry,
    fields: vector<String>,
    values: vector<String>,
    _: Permit<T>,
    ctx: &mut TxContext,
) {
    let (mut display, cap) = display_registry::new<Attestation<T>>(
        display_registry,
        std::internal::permit<Attestation<T>>(),
        ctx,
    );
    fields.zip_do!(values, |field, value| display.set(&cap, field, value));
    display_registry::share(display);

    // Lock the DisplayCap inside a frozen wrapper so the template is
    // permanently immutable. The wrapper struct's `cap` field is private to
    // this module, so external code can't extract the cap; freezing makes
    // the wrapper itself immovable; together that's equivalent in effect to
    // destroying the cap (which the framework doesn't expose a way to do).
    transfer::freeze_object(DisplayLock<T> { id: object::new(ctx), cap });
}

// === Test seam ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Test-only mirror of the `borrow`/`put_back` pattern documented in
/// docs/future-extensions.md. Production callers can't reach this, so the
/// hot-potato discipline isn't required here — tests just receive,
/// inspect, and put back manually.
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
