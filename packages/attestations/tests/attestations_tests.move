#[test_only]
module attestations::attestations_tests;

use std::unit_test::assert_eq;
use sui::test_scenario;
use sui::transfer::Receiving;
use attestations::attestations::{
    Self,
    Registry,
    Box,
    Attestation,
    ERevokeFromWrongBox,
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

/// Create both of `subject`'s boxes (active + revoked); leaves the scenario at
/// a fresh tx.
fun setup_with_box(subject: ID): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    registry.create_box(subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    scenario
}

/// The object id of `subject`'s active or revoked box.
fun box_id(registry: &Registry, subject: ID, revoked: bool): ID {
    object::id_from_address(registry.box_address(subject, revoked))
}

#[test]
fun create_box_is_idempotent() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    registry.create_box(subject);
    registry.create_box(subject); // idempotent: the second call is a no-op
    let active = box_id(&registry, subject, false);
    test_scenario::return_shared(registry);

    // The box created by the first call is intact and still shared.
    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared_by_id(active);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun attest_and_read() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let active = box_id(&registry, subject, false);
    registry.attest(permit(), subject, TestSchema { tag: 42 }, scenario.ctx());
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert_eq!(ids.length(), 1);
    let rcv: Receiving<Attestation<TestSchema>> =
        test_scenario::receiving_ticket_by_id(ids[0]);
    let a = box.borrow_for_testing(rcv);
    assert_eq!(a.subject(), subject);
    assert_eq!(a.data().tag, 42);
    box.put_back_for_testing(a);
    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun reissuance_succeeds() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let active = box_id(&registry, subject, false);
    registry.attest(permit(), subject, TestSchema { tag: 1 }, scenario.ctx());
    registry.attest(permit(), subject, TestSchema { tag: 2 }, scenario.ctx());
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert_eq!(ids.length(), 2);
    assert!(ids[0] != ids[1]);
    test_scenario::return_shared(box);
    scenario.end();
}

/// `attest` lands in the active box even before `create_box` is called — only
/// `revoke` needs the Box object. Here we attest first, then create the box and
/// read it back.
#[test]
fun attest_before_create_box() {
    let subject = subject_for(@0xBEEF);
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    // Attest with NO box created yet.
    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    registry.attest(permit(), subject, TestSchema { tag: 9 }, scenario.ctx());
    // Now create the box at the (already-populated) active address.
    registry.create_box(subject);
    let active = box_id(&registry, subject, false);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert_eq!(ids.length(), 1);
    test_scenario::return_shared(box);
    scenario.end();
}

/// Revocation moves the attestation out of the active box and into the
/// subject's (claimed) revoked box.
#[test]
fun revoke_moves_to_revoked_box() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let active = box_id(&registry, subject, false);
    let revoked = box_id(&registry, subject, true);
    registry.attest(permit(), subject, TestSchema { tag: 7 }, scenario.ctx());
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    let att_id = ids[0];
    test_scenario::return_shared(box);

    // Revoke from the active box. This module defines `TestSchema`, so it can
    // mint the `Permit<TestSchema>` the registry's `revoke` requires.
    scenario.next_tx(ALICE);
    let mut active_box: Box = scenario.take_shared_by_id(active);
    let rcv: Receiving<Attestation<TestSchema>> = test_scenario::receiving_ticket_by_id(att_id);
    active_box.revoke(permit(), rcv);
    test_scenario::return_shared(active_box);

    // Active box empty; the revoked box now owns the attestation.
    scenario.next_tx(ALICE);
    let active_box: Box = scenario.take_shared_by_id(active);
    assert!(
        test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
            object::id(&active_box),
        ).is_empty(),
    );
    test_scenario::return_shared(active_box);

    let revoked_box: Box = scenario.take_shared_by_id(revoked);
    let revoked_ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&revoked_box),
    );
    assert_eq!(revoked_ids.length(), 1);
    assert_eq!(revoked_ids[0], att_id);
    test_scenario::return_shared(revoked_box);

    scenario.end();
}

/// `revoke` must be handed the subject's *active* box; passing the revoked box
/// aborts `ERevokeFromWrongBox` (the guard fires before any receive).
#[test, expected_failure(abort_code = ERevokeFromWrongBox)]
fun revoke_from_wrong_box_aborts() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let active = box_id(&registry, subject, false);
    let revoked = box_id(&registry, subject, true);
    registry.attest(permit(), subject, TestSchema { tag: 5 }, scenario.ctx());
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared_by_id(active);
    let att_id = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    )[0];
    test_scenario::return_shared(box);

    // Hand `revoke` the REVOKED box instead of the active one → aborts.
    scenario.next_tx(ALICE);
    let mut revoked_box: Box = scenario.take_shared_by_id(revoked);
    let rcv: Receiving<Attestation<TestSchema>> = test_scenario::receiving_ticket_by_id(att_id);
    revoked_box.revoke(permit(), rcv);
    test_scenario::return_shared(revoked_box);
    scenario.end();
}

// `register_display` and `add_display_field` cannot be unit-tested here: they
// need the system `DisplayRegistry` (shared at `0xd`), and the only way to
// create one in tests is `display_registry::create_for_testing`, which is
// `public(package)` to the `sui` framework. Coverage for those flows needs
// integration testing on devnet/testnet or via the forking tool.
