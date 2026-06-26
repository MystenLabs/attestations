#[test_only]
module audit_example::audit_tests;

use std::string::String;
use sui::test_scenario;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};
use audit_example::audit::{Self, Audit};

const ALICE: address = @0xA11CE;

fun subject_for(addr: address): ID { addr.to_id() }
fun report_url(): String { b"https://audits.example.com/r.pdf".to_string() }

/// Verifies the cross-package attest flow: `audit_example::attest_audit`
/// produces an accessible attestation, and `attester_of<Audit>` returns
/// audit_example's package address — distinct from `attestation_registry`'s.
#[test]
fun test_attest_audit_cross_package() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    audit::attest_audit(&registry, subject, 9, report_url(), scenario.ctx());
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(
        object::id(&box),
    );
    let rcv: Receiving<Attestation<Audit>> = test_scenario::receiving_ticket_by_id(ids[0]);

    let a = attestation_registry::borrow_for_testing<Audit>(&mut box, rcv);
    assert!(a.subject() == subject, 0);
    assert!(a.data().score() == 9, 1);
    attestation_registry::put_back_for_testing(&mut box, a);

    // attester_of<Audit> must resolve to audit_example's package address,
    // not attestation_registry's. Compare against attester_of for a type
    // defined in attestation_registry: they must differ.
    let audit_pkg = attestation_registry::attester_of<Audit>();
    let registry_pkg = attestation_registry::attester_of<Registry>();
    assert!(audit_pkg != registry_pkg, 3);

    test_scenario::return_shared(box);
    scenario.end();
}

/// The admin-cap revocation policy: a holder of `AuditAdminCap` revokes an
/// audit, moving it out of the active box and into the revoked sink.
#[test]
fun test_revoke_audit_with_admin_cap() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    audit::attest_audit(&registry, subject, 9, report_url(), scenario.ctx());
    let sink = attestation_registry::revoked_box_address(&registry, subject);
    test_scenario::return_shared(registry);

    // Revoke with the admin cap.
    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let admin = audit::new_admin_cap_for_testing(scenario.ctx());
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(
        object::id(&box),
    );
    let id = ids[0];
    let rcv: Receiving<Attestation<Audit>> = test_scenario::receiving_ticket_by_id(id);
    audit::revoke_audit(&admin, &mut box, rcv);
    transfer::public_transfer(admin, ALICE);
    test_scenario::return_shared(box);

    // The audit left the active box for the revoked sink.
    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared();
    assert!(
        test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(
            object::id(&box),
        ).is_empty(),
        0,
    );
    assert!(test_scenario::has_most_recent_for_address<Attestation<Audit>>(sink), 1);
    test_scenario::return_shared(box);

    scenario.end();
}
