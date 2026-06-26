#[test_only]
module self_pull::self_pull_tests;

use std::string::String;
use sui::package;
use sui::test_scenario;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};
use self_pull::self_pull::{Self, SelfPull};

const ALICE: address = @0xA11CE;

fun reason(): String { b"critical bug; do not use".to_string() }

/// Share the Registry and create a Box for `subject`; leaves the scenario at a
/// fresh tx ready to `take_shared`.
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

/// `attest_self_pull` lands an `Attestation<SelfPull>` in the subject's active
/// box, and the recorded attester is self_pull's package (distinct from
/// attestation_registry's).
#[test]
fun test_attest_self_pull() {
    let subject = @0xBEEF.to_id();
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap = package::test_publish(subject, scenario.ctx());
    assert!(package::upgrade_package(&cap) == subject, 0);
    self_pull::attest_self_pull(&registry, &cap, reason(), scenario.ctx());
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<SelfPull>>(
        object::id(&box),
    );
    assert!(ids.length() == 1, 1);
    let rcv: Receiving<Attestation<SelfPull>> = test_scenario::receiving_ticket_by_id(ids[0]);
    let a = attestation_registry::borrow_for_testing<SelfPull>(&mut box, rcv);
    assert!(a.subject() == subject, 2);
    attestation_registry::put_back_for_testing(&mut box, a);
    test_scenario::return_shared(box);

    assert!(
        attestation_registry::attester_of<SelfPull>()
            != attestation_registry::attester_of<Registry>(),
        3,
    );

    package::make_immutable(cap);
    scenario.end();
}

/// `revoke_self_pull`, gated by the same `UpgradeCap`, moves the attestation out
/// of the active box and into the subject's revoked sink.
#[test]
fun test_revoke_self_pull() {
    let subject = @0xBEEF.to_id();
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap = package::test_publish(subject, scenario.ctx());
    self_pull::attest_self_pull(&registry, &cap, reason(), scenario.ctx());
    let sink = attestation_registry::revoked_box_address(&registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<SelfPull>>(
        object::id(&box),
    );
    let rcv: Receiving<Attestation<SelfPull>> = test_scenario::receiving_ticket_by_id(ids[0]);
    self_pull::revoke_self_pull(&cap, &mut box, rcv);
    test_scenario::return_shared(box);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared();
    assert!(
        test_scenario::receivable_object_ids_for_owner_id<Attestation<SelfPull>>(
            object::id(&box),
        ).is_empty(),
        0,
    );
    assert!(test_scenario::has_most_recent_for_address<Attestation<SelfPull>>(sink), 1);
    test_scenario::return_shared(box);

    package::make_immutable(cap);
    scenario.end();
}

/// `revoke_self_pull` requires the `UpgradeCap` of the box's subject: a cap for
/// a *different* package can't rescind this package's self-pull.
#[test, expected_failure]
fun test_revoke_requires_matching_cap() {
    let subject = @0xBEEF.to_id();
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap = package::test_publish(subject, scenario.ctx());
    self_pull::attest_self_pull(&registry, &cap, reason(), scenario.ctx());
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<SelfPull>>(
        object::id(&box),
    );
    let rcv: Receiving<Attestation<SelfPull>> = test_scenario::receiving_ticket_by_id(ids[0]);
    // A cap for a different package must not be able to revoke this self-pull.
    let wrong = package::test_publish(@0xFEED.to_id(), scenario.ctx());
    self_pull::revoke_self_pull(&wrong, &mut box, rcv);

    package::make_immutable(wrong);
    package::make_immutable(cap);
    test_scenario::return_shared(box);
    scenario.end();
}

/// The subject follows the cap: a cap governing a *different* package (with no
/// Box) can't attest — `attest` aborts on the missing Box, so you can only
/// self-pull the package your `UpgradeCap` actually governs.
#[test, expected_failure]
fun test_attest_follows_the_cap() {
    let subject = @0xBEEF.to_id();
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap = package::test_publish(@0xFEED.to_id(), scenario.ctx());
    self_pull::attest_self_pull(&registry, &cap, reason(), scenario.ctx());
    test_scenario::return_shared(registry);

    package::make_immutable(cap);
    scenario.end();
}
