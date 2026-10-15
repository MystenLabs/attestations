#[test_only]
module auditor::audit_tests;

use std::string::String;
use std::unit_test::assert_eq;
use sui::test_scenario::{Self, Scenario};
use sui::transfer::Receiving;
use attestations::attestations::{Self, Registry, Box, Attestation};
use auditor::audit::{Self, Audit};

const ALICE: address = @0xA11CE;

fun subject_for(addr: address): ID { addr.to_id() }
fun description(): String { b"Clean audit — no findings.".to_string() }
fun report_url(): String { b"https://audits.example.com/r.pdf".to_string() }
fun published_at(): u64 { 1_700_000_000_000 }

/// Publish the registry and create `subject`'s active box. Returns the scenario
/// at a fresh tx, plus the registry's id — all that `attest_audit` and the
/// box-address derivations need.
fun setup_with_box(subject: ID): (Scenario, ID) {
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    let registry_id = object::id(&registry);
    registry.create_box(subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    (scenario, registry_id)
}

/// The id form of `subject`'s active or revoked box address.
fun box_id(registry: ID, subject: ID, revoked: bool): ID {
    object::id_from_address(attestations::box_address(registry, subject, revoked))
}

/// The ids of the audits owned by `owner`, which is a box address — no object
/// need exist there, which is how the revoked address is read.
fun audit_ids(owner: ID): vector<ID> {
    test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(owner)
}

/// Verifies the cross-package attest flow: `auditor::attest_audit` produces an
/// accessible attestation, and `attester_of<Audit>` returns auditor's package
/// address — distinct from `attestations`'s.
#[test]
fun attest_audit_cross_package() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry) = setup_with_box(subject);
    let active = box_id(registry, subject, false);

    let admin = audit::new_admin_cap_for_testing(scenario.ctx());
    admin.attest_audit(registry, subject, description(), report_url(), published_at(), scenario.ctx());
    transfer::public_transfer(admin, ALICE);

    scenario.next_tx(ALICE);
    let ids = audit_ids(active);
    assert_eq!(ids.length(), 1);
    scenario.with_shared_by_id!<Box>(active, |box, _| {
        let rcv: Receiving<Attestation<Audit>> = test_scenario::receiving_ticket_by_id(ids[0]);
        let a = box.borrow_for_testing(rcv);
        assert_eq!(a.subject(), subject);
        box.put_back_for_testing(a);
    });

    // attester_of<Audit> must resolve to auditor's package address, not
    // attestations's.
    assert!(attestations::attester_of<Audit>() != attestations::attester_of<Registry>());

    scenario.end();
}

/// The admin-cap policy: a holder of `AuditAdminCap` issues then revokes an
/// audit, moving it from the active box onto the revoked address.
#[test]
fun revoke_audit_with_admin_cap() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry) = setup_with_box(subject);
    let active = box_id(registry, subject, false);
    let revoked = box_id(registry, subject, true);

    let admin = audit::new_admin_cap_for_testing(scenario.ctx());
    admin.attest_audit(registry, subject, description(), report_url(), published_at(), scenario.ctx());

    scenario.next_tx(ALICE);
    let id = audit_ids(active)[0];
    scenario.with_shared_by_id!<Box>(active, |box, _| {
        let rcv: Receiving<Attestation<Audit>> = test_scenario::receiving_ticket_by_id(id);
        admin.revoke_audit(box, rcv);
    });
    transfer::public_transfer(admin, ALICE);

    // The audit left the active box for the revoked address (no Box there).
    scenario.next_tx(ALICE);
    assert!(audit_ids(active).is_empty());
    assert_eq!(audit_ids(revoked).length(), 1);
    assert_eq!(audit_ids(revoked)[0], id);

    scenario.end();
}
