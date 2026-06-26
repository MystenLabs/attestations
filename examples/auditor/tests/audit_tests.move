#[test_only]
module auditor::audit_tests;

use std::string::String;
use std::unit_test::assert_eq;
use sui::test_scenario;
use sui::transfer::Receiving;
use attestations::attestations::{Self, Registry, Box, Attestation};
use auditor::audit::{Self, Audit};

const ALICE: address = @0xA11CE;

fun subject_for(addr: address): ID { addr.to_id() }
fun description(): String { b"Clean audit — no findings.".to_string() }
fun report_url(): String { b"https://audits.example.com/r.pdf".to_string() }
fun publish_date(): u64 { 1_700_000_000_000 }

fun box_id(registry: &Registry, subject: ID, revoked: bool): ID {
    object::id_from_address(registry.box_address(subject, revoked))
}

/// Verifies the cross-package attest flow: `auditor::attest_audit` produces an
/// accessible attestation, and `attester_of<Audit>` returns auditor's package
/// address — distinct from `attestations`'s.
#[test]
fun attest_audit_cross_package() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    registry.create_box(subject);
    let active = box_id(&registry, subject, false);
    let admin = audit::new_admin_cap_for_testing(scenario.ctx());
    admin.attest_audit(&registry, subject, description(), report_url(), publish_date(), scenario.ctx());
    transfer::public_transfer(admin, ALICE);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(
        object::id(&box),
    );
    let rcv: Receiving<Attestation<Audit>> = test_scenario::receiving_ticket_by_id(ids[0]);
    let a = box.borrow_for_testing(rcv);
    assert_eq!(a.subject(), subject);
    box.put_back_for_testing(a);

    // attester_of<Audit> must resolve to auditor's package address, not
    // attestations's.
    let audit_pkg = attestations::attester_of<Audit>();
    let registry_pkg = attestations::attester_of<Registry>();
    assert!(audit_pkg != registry_pkg);

    test_scenario::return_shared(box);
    scenario.end();
}

/// The admin-cap policy: a holder of `AuditAdminCap` issues then revokes an
/// audit, moving it from the active box into the (claimed) revoked box.
#[test]
fun revoke_audit_with_admin_cap() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    registry.create_box(subject);
    let active = box_id(&registry, subject, false);
    let revoked = box_id(&registry, subject, true);
    let admin = audit::new_admin_cap_for_testing(scenario.ctx());
    admin.attest_audit(&registry, subject, description(), report_url(), publish_date(), scenario.ctx());
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared_by_id(active);
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(
        object::id(&box),
    );
    let id = ids[0];
    test_scenario::return_shared(box);

    scenario.next_tx(ALICE);
    let mut active_box: Box = scenario.take_shared_by_id(active);
    let rcv: Receiving<Attestation<Audit>> = test_scenario::receiving_ticket_by_id(id);
    admin.revoke_audit(&mut active_box, rcv);
    transfer::public_transfer(admin, ALICE);
    test_scenario::return_shared(active_box);

    // The audit left the active box for the revoked box.
    scenario.next_tx(ALICE);
    let active_box: Box = scenario.take_shared_by_id(active);
    assert!(
        test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(
            object::id(&active_box),
        ).is_empty(),
    );
    test_scenario::return_shared(active_box);
    let revoked_box: Box = scenario.take_shared_by_id(revoked);
    assert_eq!(
        test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(
            object::id(&revoked_box),
        ).length(),
        1,
    );
    test_scenario::return_shared(revoked_box);

    scenario.end();
}
