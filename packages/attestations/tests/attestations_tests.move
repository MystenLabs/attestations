#[test_only]
module attestations::attestations_tests;

use std::unit_test::assert_eq;
use sui::test_scenario::{Self, Scenario};
use sui::transfer::Receiving;
use attestations::attestations::{
    Self,
    Registry,
    Box,
    Attestation,
};

const ALICE: address = @0xA11CE;

/// Test-only schema. Defined here so this module is its `Permit<TestSchema>`
/// minting authority (the registry's `attest`/`revoke` require it).
public struct TestSchema has store, drop {
    tag: u8,
}

fun subject_for(addr: address): ID { addr.to_id() }

/// A `Permit<TestSchema>` — only this module (TestSchema's definer) can mint it.
fun permit(): std::internal::Permit<TestSchema> { std::internal::permit<TestSchema>() }

/// Publish the registry. Returns the scenario at a fresh tx, plus the registry's
/// id — all that `attest` and the box-address derivations need, so no test but
/// this one has to take the shared `Registry`.
fun begin(): (Scenario, ID) {
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    let registry_id = object::id(&registry);
    test_scenario::return_shared(registry);

    // Close the tx: a returned shared object only re-enters the inventory that
    // `take_shared` reads at a tx boundary, so without this the next take aborts
    // on an empty inventory.
    scenario.next_tx(ALICE);
    (scenario, registry_id)
}

/// As `begin`, but with `subject`'s active box already created.
fun setup_with_box(subject: ID): (Scenario, ID) {
    let (mut scenario, registry) = begin();
    scenario.with_shared!<Registry>(|reg, _| reg.create_box(subject));

    scenario.next_tx(ALICE);
    (scenario, registry)
}

/// The id form of `subject`'s active or revoked box address.
fun box_id(registry: ID, subject: ID, revoked: bool): ID {
    object::id_from_address(attestations::box_address(registry, subject, revoked))
}

/// The ids of the attestations owned by `owner`, which is a box address — no
/// object need exist there, which is how the revoked address is read.
fun attestation_ids(owner: ID): vector<ID> {
    test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(owner)
}

#[test]
fun create_box_is_idempotent() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry) = begin();

    scenario.with_shared!<Registry>(|reg, _| {
        reg.create_box(subject);
        reg.create_box(subject); // idempotent: the second call is a no-op
    });

    // The box created by the first call is intact and still shared.
    scenario.next_tx(ALICE);
    let active = box_id(registry, subject, false);
    scenario.with_shared_by_id!<Box>(active, |box, _| {
        assert!(attestation_ids(object::id(box)).is_empty());
    });
    scenario.end();
}

#[test]
fun attest_and_read() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry) = setup_with_box(subject);
    let active = box_id(registry, subject, false);

    attestations::attest(registry, permit(), subject, TestSchema { tag: 42 }, scenario.ctx());

    scenario.next_tx(ALICE);
    let ids = attestation_ids(active);
    assert_eq!(ids.length(), 1);
    scenario.with_shared_by_id!<Box>(active, |box, _| {
        let rcv: Receiving<Attestation<TestSchema>> =
            test_scenario::receiving_ticket_by_id(ids[0]);
        let a = box.borrow_for_testing(rcv);
        assert_eq!(a.subject(), subject);
        assert_eq!(a.data().tag, 42);
        box.put_back_for_testing(a);
    });
    scenario.end();
}

#[test]
fun reissuance_succeeds() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry) = setup_with_box(subject);
    let active = box_id(registry, subject, false);

    attestations::attest(registry, permit(), subject, TestSchema { tag: 1 }, scenario.ctx());
    attestations::attest(registry, permit(), subject, TestSchema { tag: 2 }, scenario.ctx());

    scenario.next_tx(ALICE);
    let ids = attestation_ids(active);
    assert_eq!(ids.length(), 2);
    assert!(ids[0] != ids[1]);
    scenario.end();
}

/// `attest` lands in the active box even before `create_box` is called — only
/// `revoke` needs the Box object. Here we attest first, then create the box and
/// read it back.
#[test]
fun attest_before_create_box() {
    let subject = subject_for(@0xBEEF);
    let (mut scenario, registry) = begin();

    // Attest with NO box created yet.
    attestations::attest(registry, permit(), subject, TestSchema { tag: 9 }, scenario.ctx());
    // Now create the box at the (already-populated) active address.
    scenario.with_shared!<Registry>(|reg, _| reg.create_box(subject));

    scenario.next_tx(ALICE);
    assert_eq!(attestation_ids(box_id(registry, subject, false)).length(), 1);
    scenario.end();
}

/// Revocation moves the attestation out of the active box and onto the
/// subject's revoked address.
#[test]
fun revoke_moves_to_revoked_box() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry) = setup_with_box(subject);
    let active = box_id(registry, subject, false);
    let revoked = box_id(registry, subject, true);

    attestations::attest(registry, permit(), subject, TestSchema { tag: 7 }, scenario.ctx());

    scenario.next_tx(ALICE);
    let att_id = attestation_ids(active)[0];

    // Revoke from the active box. This module defines `TestSchema`, so it can
    // mint the `Permit<TestSchema>` the registry's `revoke` requires.
    scenario.with_shared_by_id!<Box>(active, |box, _| {
        let rcv: Receiving<Attestation<TestSchema>> =
            test_scenario::receiving_ticket_by_id(att_id);
        box.revoke(permit(), rcv);
    });

    // Active box empty; the revoked address now owns the attestation.
    scenario.next_tx(ALICE);
    assert!(attestation_ids(active).is_empty());

    // No Box object exists at the revoked address; the attestation is simply
    // owned by that address, which is what off-chain consumers read.
    let revoked_ids = attestation_ids(revoked);
    assert_eq!(revoked_ids.length(), 1);
    assert_eq!(revoked_ids[0], att_id);

    scenario.end();
}

// `register_display` and `add_display_field` cannot be unit-tested here: they
// need the system `DisplayRegistry` (shared at `0xd`), and the only way to
// create one in tests is `display_registry::create_for_testing`, which is
// `public(package)` to the `sui` framework. Coverage for those flows needs
// integration testing on devnet/testnet or via the forking tool.
