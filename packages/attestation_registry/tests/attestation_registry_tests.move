#[test_only]
module attestation_registry::attestation_registry_tests;

use sui::test_scenario;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{
    Self,
    Registry,
    Box,
    Attestation,
    EBoxAlreadyExists,
    EBoxDoesNotExist,
};

const ALICE: address = @0xA11CE;

/// Test-only schema. Defined here so this module is its `Permit<TestSchema>`
/// minting authority.
public struct TestSchema has store, drop {
    tag: u8,
}

fun subject_for(addr: address): ID { addr.to_id() }

/// Drive a scenario forward to the state where `Box` for `subject` is shared
/// and ready to be `take_shared`'d.
fun setup_with_box(subject: ID): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    scenario
}

#[test, expected_failure(abort_code = EBoxAlreadyExists)]
fun test_create_box_aborts_on_duplicate() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = EBoxDoesNotExist)]
fun test_attest_aborts_when_box_missing() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    attestation_registry::attest<TestSchema>(
        &registry,
        subject,
        TestSchema { tag: 1 },
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test]
fun test_attest_and_read() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    attestation_registry::attest<TestSchema>(
        &registry,
        subject,
        TestSchema { tag: 42 },
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert!(ids.length() == 1, 0);
    let rcv: Receiving<Attestation<TestSchema>> =
        test_scenario::receiving_ticket_by_id(ids[0]);

    let a = attestation_registry::borrow_for_testing<TestSchema>(&mut box, rcv);
    assert!(a.subject() == subject, 1);
    assert!(a.data().tag == 42, 2);
    attestation_registry::put_back_for_testing(&mut box, a);

    test_scenario::return_shared(box);
    scenario.end();
}

#[test]
fun test_reissuance_succeeds() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    attestation_registry::attest<TestSchema>(
        &registry, subject, TestSchema { tag: 1 },
        scenario.ctx(),
    );
    attestation_registry::attest<TestSchema>(
        &registry, subject, TestSchema { tag: 2 },
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert!(ids.length() == 2, 0);
    assert!(ids[0] != ids[1], 1);
    test_scenario::return_shared(box);
    scenario.end();
}

/// Revocation moves the attestation out of the active box and into the
/// subject's revoked sink: the active box empties, the sink (a bare address)
/// now owns it.
#[test]
fun test_revoke_moves_attestation_to_sink() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    attestation_registry::attest<TestSchema>(
        &registry, subject, TestSchema { tag: 7 },
        scenario.ctx(),
    );
    let sink = attestation_registry::revoked_box_address(&registry, subject);
    test_scenario::return_shared(registry);

    // Pre-revoke: the attestation is in the active box; the sink is empty.
    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
        object::id(&box),
    );
    assert!(ids.length() == 1, 0);
    let id = ids[0];
    assert!(!test_scenario::has_most_recent_for_address<Attestation<TestSchema>>(sink), 1);
    test_scenario::return_shared(box);

    // Revoke. The test module defines `TestSchema`, so it can mint the
    // `Permit<TestSchema>` the registry's `revoke` requires.
    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let rcv: Receiving<Attestation<TestSchema>> = test_scenario::receiving_ticket_by_id(id);
    attestation_registry::revoke<TestSchema>(
        &mut box, std::internal::permit<TestSchema>(), rcv,
    );
    test_scenario::return_shared(box);

    // Post-revoke: the active box no longer holds it; the sink now does.
    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared();
    assert!(
        test_scenario::receivable_object_ids_for_owner_id<Attestation<TestSchema>>(
            object::id(&box),
        ).is_empty(),
        2,
    );
    assert!(test_scenario::has_most_recent_for_address<Attestation<TestSchema>>(sink), 3);
    test_scenario::return_shared(box);

    scenario.end();
}

// Revocation authority is no longer the base registry's concern (it gates
// `revoke` on `Permit<T>` and leaves the policy to the schema), so any
// per-attestation cap-mismatch policy is tested by the schema that
// reconstructs that bearer-cap pattern, not here.

// `register_display` cannot be unit-tested here: it needs the system
// `DisplayRegistry` (shared at `0xd`), and the only way to create one in tests
// is `display_registry::create_for_testing`, which is `public(package)` to the
// `sui` framework. Coverage for that flow needs integration testing on
// devnet/testnet or via the forking tool.
