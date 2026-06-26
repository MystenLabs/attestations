#[test_only]
module vuln_example::vuln_tests;

use std::string::String;
use sui::test_scenario;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};
use vuln_example::vuln::{Self, Vulnerability, EVulnRevokeMismatch};

const ALICE: address = @0xA11CE;

fun subject_for(addr: address): ID { addr.to_id() }
fun cve(): String { b"CVE-2026-1234".to_string() }
fun advisory(): String { b"https://scanner.example.com/CVE-2026-1234".to_string() }

/// Set up a shared `Box` for `subject` and return the scenario positioned
/// just after, ready to attest.
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

/// Verifies the cross-package attest flow for vuln_example, and that
/// `attester_of<Vulnerability>` resolves to vuln_example's package address —
/// distinct from attestation_registry's and from audit_example's.
#[test]
fun test_attest_vuln_cross_package() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = test_scenario::begin(ALICE);
    attestation_registry::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let mut registry: Registry = scenario.take_shared();
    attestation_registry::create_box(&mut registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    let cap = vuln::attest_vuln(
        &registry,
        subject,
        7,
        cve(),
        b"Reentrancy in withdraw".to_string(),
        advisory(),
        scenario.ctx(),
    );
    transfer::public_transfer(cap, ALICE);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Vulnerability>>(
        object::id(&box),
    );
    let rcv: Receiving<Attestation<Vulnerability>> =
        test_scenario::receiving_ticket_by_id(ids[0]);

    let a = attestation_registry::borrow_for_testing<Vulnerability>(&mut box, rcv);
    assert!(a.subject() == subject, 0);
    assert!(a.data().severity() == 7, 1);
    assert!(a.data().cve_id() == cve(), 2);
    attestation_registry::put_back_for_testing(&mut box, a);

    // attester_of<Vulnerability> must resolve to vuln_example's address —
    // distinct from attestation_registry's.
    let vuln_pkg = attestation_registry::attester_of<Vulnerability>();
    let registry_pkg = attestation_registry::attester_of<Registry>();
    assert!(vuln_pkg != registry_pkg, 4);

    test_scenario::return_shared(box);
    scenario.end();
}

/// Attest, then revoke with the matching `VulnRevokeCap`: the vuln moves out
/// of the active box into the subject's revoked sink.
#[test]
fun test_revoke_vuln_with_matching_cap() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap = vuln::attest_vuln(
        &registry, subject, 7, cve(), b"desc".to_string(), advisory(), scenario.ctx(),
    );
    let sink = attestation_registry::revoked_box_address(&registry, subject);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Vulnerability>>(
        object::id(&box),
    );
    let id = ids[0];
    let rcv: Receiving<Attestation<Vulnerability>> = test_scenario::receiving_ticket_by_id(id);
    vuln::revoke_vuln(cap, &mut box, rcv);
    test_scenario::return_shared(box);

    // The vuln left the active box for the revoked sink.
    scenario.next_tx(ALICE);
    let box: Box = scenario.take_shared();
    assert!(
        test_scenario::receivable_object_ids_for_owner_id<Attestation<Vulnerability>>(
            object::id(&box),
        ).is_empty(),
        0,
    );
    assert!(test_scenario::has_most_recent_for_address<Attestation<Vulnerability>>(sink), 1);
    test_scenario::return_shared(box);

    scenario.end();
}

/// A `VulnRevokeCap` bound to attestation A can't revoke attestation B —
/// the schema-side binding guard aborts `EVulnRevokeMismatch`.
#[test, expected_failure(abort_code = EVulnRevokeMismatch)]
fun test_revoke_vuln_with_wrong_cap_aborts() {
    let subject = subject_for(@0xDEAD);
    let mut scenario = setup_with_box(subject);

    let registry: Registry = scenario.take_shared();
    let cap_a = vuln::attest_vuln(
        &registry, subject, 7, cve(), b"a".to_string(), advisory(), scenario.ctx(),
    );
    let cap_b = vuln::attest_vuln(
        &registry, subject, 5, cve(), b"b".to_string(), advisory(), scenario.ctx(),
    );
    transfer::public_transfer(cap_b, ALICE);
    test_scenario::return_shared(registry);

    scenario.next_tx(ALICE);
    let mut box: Box = scenario.take_shared();
    let ids = test_scenario::receivable_object_ids_for_owner_id<Attestation<Vulnerability>>(
        object::id(&box),
    );
    // Pair cap_a with the *other* attestation's receiving ticket — must abort.
    let want = vuln::cap_attestation_id(&cap_a);
    let wrong = if (ids[0] == want) ids[1] else ids[0];
    let rcv: Receiving<Attestation<Vulnerability>> = test_scenario::receiving_ticket_by_id(wrong);
    vuln::revoke_vuln(cap_a, &mut box, rcv);

    test_scenario::return_shared(box); // unreachable
    scenario.end();
}
