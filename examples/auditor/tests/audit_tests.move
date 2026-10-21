#[test_only]
module auditor::audit_tests;

use attestations::attestations::{Self, Registry, Attestation};
use auditor::audit::{Self, Audit, AuditAdminCap};
use std::string::String;
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::derived_object;
use sui::test_scenario::{Self, Scenario};

const ALICE: address = @0xA11CE;

fun subject_for(addr: address): ID { addr.to_id() }

fun description(): String { b"Clean audit — no findings.".to_string() }

fun report_url(): String { b"https://audits.example.com/r.pdf".to_string() }

fun report_hash(): Option<String> {
    option::some(b"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".to_string())
}

fun published_at(): u64 { 1_700_000_000_000 }

/// Publish the registry. Returns the scenario at a fresh tx, plus the address
/// `subject`'s attestations live at, derived from the registry's id the way an
/// off-chain consumer derives it.
fun setup(subject: ID): (Scenario, address) {
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    let anchor = derived_object::derive_address(object::id(&registry), subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    (scenario, anchor)
}

/// The ids of the audits at `anchor`, live and revoked alike.
fun audit_ids(anchor: address): vector<ID> {
    test_scenario::receivable_object_ids_for_owner_id<Attestation<Audit>>(anchor.to_id())
}

/// Issue one audit about `subject` through the shared registry.
fun attest(
    scenario: &mut Scenario,
    admin: &AuditAdminCap,
    subject: ID,
    report_hash: Option<String>,
    clock: &Clock,
) {
    scenario.with_shared!<Registry>(|registry, scenario| {
        admin.attest_audit(
            registry,
            subject,
            description(),
            report_url(),
            report_hash,
            published_at(),
            clock,
            scenario.ctx(),
        );
    });
}

/// Verifies the cross-package attest flow: `auditor::attest_audit` lands a live
/// attestation about `subject` at the address derived for it.
#[test]
fun attest_audit_cross_package() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, anchor) = setup(subject);
    let clock = clock::create_for_testing(scenario.ctx());

    let admin = audit::new_admin_cap_for_testing(scenario.ctx());
    attest(&mut scenario, &admin, subject, report_hash(), &clock);
    transfer::public_transfer(admin, ALICE);

    scenario.next_tx(ALICE);
    let ids = audit_ids(anchor);
    assert_eq!(ids.length(), 1);
    let a: Attestation<Audit> = scenario.take_from_address_by_id(anchor, ids[0]);
    assert_eq!(a.package(), subject);
    assert!(a.revoked_at_ms().is_none());
    test_scenario::return_to_address(anchor, a);

    clock.destroy_for_testing();
    scenario.end();
}

/// The admin-cap policy: a holder of `AuditAdminCap` issues then revokes an
/// audit. It stays at the subject's address, stamped with the revocation time.
#[test]
fun revoke_audit_with_admin_cap() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, anchor) = setup(subject);
    let mut clock = clock::create_for_testing(scenario.ctx());

    let admin = audit::new_admin_cap_for_testing(scenario.ctx());
    attest(&mut scenario, &admin, subject, report_hash(), &clock);

    scenario.next_tx(ALICE);
    let id = audit_ids(anchor)[0];
    clock.set_for_testing(published_at());
    scenario.with_shared!<Registry>(|registry, scenario| {
        admin.revoke_audit(
            registry,
            subject,
            test_scenario::receiving_ticket_by_id(id),
            &clock,
            scenario.ctx(),
        );
    });
    transfer::public_transfer(admin, ALICE);

    scenario.next_tx(ALICE);
    assert_eq!(audit_ids(anchor), vector[id]);
    let a: Attestation<Audit> = scenario.take_from_address_by_id(anchor, id);
    assert_eq!(a.revoked_at_ms(), option::some(published_at()));
    test_scenario::return_to_address(anchor, a);

    clock.destroy_for_testing();
    scenario.end();
}

/// The report digest is optional: attesting with `none` still produces an audit.
#[test]
fun attest_audit_without_report_hash() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, anchor) = setup(subject);
    let clock = clock::create_for_testing(scenario.ctx());

    let admin = audit::new_admin_cap_for_testing(scenario.ctx());
    attest(&mut scenario, &admin, subject, option::none(), &clock);
    transfer::public_transfer(admin, ALICE);

    scenario.next_tx(ALICE);
    assert_eq!(audit_ids(anchor).length(), 1);

    clock.destroy_for_testing();
    scenario.end();
}
