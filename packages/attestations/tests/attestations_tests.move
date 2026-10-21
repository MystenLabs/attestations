#[test_only]
module attestations::attestations_tests;

use attestations::attestations::{Self, Registry, Attestation, Attested, Revoked};
use std::internal::Permit;
use std::unit_test::assert_eq;
use sui::clock::{Self, Clock};
use sui::derived_object;
use sui::event;
use sui::test_scenario::{Self, Scenario};

const ALICE: address = @0xA11CE;

/// The clock when the tests attest, and when they revoke.
const CREATED_MS: u64 = 1_000;
const REVOKED_MS: u64 = 2_000;

/// Two test schemas. Defined here, so this module mints their permits, as a
/// schema's own module would.
public struct Audit has drop, store {
    score: u8,
}

public struct Review has drop, store {
    score: u8,
}

fun audit(): Permit<Audit> { std::internal::permit<Audit>() }

fun review(): Permit<Review> { std::internal::permit<Review>() }

fun subject_for(addr: address): ID { addr.to_id() }

/// Publish the registry. Returns the scenario at a fresh tx, the registry's
/// id, and a clock at `CREATED_MS`.
fun begin(): (Scenario, ID, Clock) {
    let mut scenario = test_scenario::begin(ALICE);
    attestations::init_for_testing(scenario.ctx());

    scenario.next_tx(ALICE);
    let registry: Registry = scenario.take_shared();
    let registry_id = object::id(&registry);
    test_scenario::return_shared(registry);

    // Close the tx: a returned shared object only re-enters the inventory that
    // `take_shared` reads at a tx boundary.
    scenario.next_tx(ALICE);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(CREATED_MS);
    (scenario, registry_id, clock)
}

fun finish(scenario: Scenario, clock: Clock) {
    clock.destroy_for_testing();
    scenario.end();
}

/// The address `subject`'s attestations live at, derived the way an off-chain
/// consumer derives it: from the registry's id and the subject alone.
fun address_of(registry: ID, subject: ID): address {
    derived_object::derive_address(registry, subject)
}

/// The ids of the `Attestation<T>`s at `subject`'s address, live and revoked
/// alike.
fun ids<T: store>(registry: ID, subject: ID): vector<ID> {
    test_scenario::receivable_object_ids_for_owner_id<Attestation<T>>(address_of(
        registry,
        subject,
    ).to_id())
}

/// Attest about `subject` through the shared registry.
fun attest<T: store>(
    scenario: &mut Scenario,
    permit: Permit<T>,
    subject: ID,
    data: T,
    clock: &Clock,
) {
    scenario.with_shared!<Registry>(|registry, scenario| {
        registry.attest(permit, subject, data, clock, scenario.ctx());
    });
}

/// Revoke the `Attestation<T>` with id `id`, naming `subject` as its subject.
fun revoke<T: store>(
    scenario: &mut Scenario,
    permit: Permit<T>,
    subject: ID,
    id: ID,
    clock: &Clock,
) {
    scenario.with_shared!<Registry>(|registry, scenario| {
        registry.revoke(
            permit,
            subject,
            test_scenario::receiving_ticket_by_id<Attestation<T>>(id),
            clock,
            scenario.ctx(),
        );
    });
}

/// An attestation lands at the address derived from the registry's id and its
/// subject: live, stamped with the clock, and with its data intact.
#[test]
fun attest_lands_at_derived_address() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry, clock) = begin();
    attest(&mut scenario, audit(), subject, Audit { score: 90 }, &clock);

    scenario.next_tx(ALICE);
    let found = ids<Audit>(registry, subject);
    assert_eq!(found.length(), 1);
    let at = address_of(registry, subject);
    let a: Attestation<Audit> = scenario.take_from_address_by_id(at, found[0]);
    assert_eq!(a.subject(), subject);
    assert_eq!(a.data().score, 90);
    assert_eq!(a.created_at_ms(), CREATED_MS);
    assert!(a.revoked_at_ms().is_none());
    test_scenario::return_to_address(at, a);
    finish(scenario, clock);
}

/// Attesting needs nothing but the registry, with no setup per subject. Each
/// subject has its own address, and one subject's attestations sit side by
/// side there.
#[test]
fun attest_keeps_subjects_apart() {
    let (one, other) = (subject_for(@0xDEAD), subject_for(@0xBEEF));
    let (mut scenario, registry, clock) = begin();
    attest(&mut scenario, audit(), one, Audit { score: 1 }, &clock);
    scenario.next_tx(ALICE);
    attest(&mut scenario, audit(), one, Audit { score: 2 }, &clock);
    scenario.next_tx(ALICE);
    attest(&mut scenario, audit(), other, Audit { score: 3 }, &clock);

    scenario.next_tx(ALICE);
    assert!(address_of(registry, one) != address_of(registry, other));
    assert_eq!(ids<Audit>(registry, one).length(), 2);
    assert_eq!(ids<Audit>(registry, other).length(), 1);
    finish(scenario, clock);
}

/// The first revoke for a subject creates its anchor on the spot, with no
/// setup transaction. The attestation stays at its address, stamped with the
/// revocation time, with its data intact.
#[test]
fun first_revoke_creates_the_anchor() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry, mut clock) = begin();
    attest(&mut scenario, audit(), subject, Audit { score: 90 }, &clock);

    scenario.next_tx(ALICE);
    let id = ids<Audit>(registry, subject)[0];
    clock.set_for_testing(REVOKED_MS);
    revoke(&mut scenario, audit(), subject, id, &clock);

    scenario.next_tx(ALICE);
    assert_eq!(ids<Audit>(registry, subject), vector[id]);
    let at = address_of(registry, subject);
    let a: Attestation<Audit> = scenario.take_from_address_by_id(at, id);
    assert_eq!(a.revoked_at_ms(), option::some(REVOKED_MS));
    assert_eq!(a.created_at_ms(), CREATED_MS);
    assert_eq!(a.data().score, 90);
    test_scenario::return_to_address(at, a);
    finish(scenario, clock);
}

/// A subject's later revokes reuse the anchor its first revoke created.
#[test]
fun later_revoke_reuses_the_anchor() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry, clock) = begin();
    attest(&mut scenario, audit(), subject, Audit { score: 1 }, &clock);
    scenario.next_tx(ALICE);
    attest(&mut scenario, audit(), subject, Audit { score: 2 }, &clock);

    scenario.next_tx(ALICE);
    let found = ids<Audit>(registry, subject);
    revoke(&mut scenario, audit(), subject, found[0], &clock);
    scenario.next_tx(ALICE);
    revoke(&mut scenario, audit(), subject, found[1], &clock);

    scenario.next_tx(ALICE);
    let at = address_of(registry, subject);
    found.do!(|id| {
        let a: Attestation<Audit> = scenario.take_from_address_by_id(at, id);
        assert!(a.revoked_at_ms().is_some());
        test_scenario::return_to_address(at, a);
    });
    finish(scenario, clock);
}

/// Revocation is terminal: revoking a revoked attestation aborts, so its
/// revocation time can't be overwritten.
#[test, expected_failure(abort_code = attestations::EAlreadyRevoked)]
fun revoke_twice_aborts() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry, clock) = begin();
    attest(&mut scenario, audit(), subject, Audit { score: 90 }, &clock);

    scenario.next_tx(ALICE);
    let id = ids<Audit>(registry, subject)[0];
    revoke(&mut scenario, audit(), subject, id, &clock);
    // A fresh ticket, so the failure is the revocation check, not a stale version.
    scenario.next_tx(ALICE);
    revoke(&mut scenario, audit(), subject, id, &clock);
    finish(scenario, clock);
}

/// An attestation can only be revoked through its own subject's anchor.
#[test, expected_failure(abort_code = sui::transfer::EUnableToReceiveObject)]
fun revoke_with_wrong_subject_aborts() {
    let (subject, other) = (subject_for(@0xDEAD), subject_for(@0xBEEF));
    let (mut scenario, registry, clock) = begin();
    attest(&mut scenario, audit(), subject, Audit { score: 90 }, &clock);

    scenario.next_tx(ALICE);
    let id = ids<Audit>(registry, subject)[0];
    revoke(&mut scenario, audit(), other, id, &clock);
    finish(scenario, clock);
}

/// Revoking one attestation leaves the others at its address alone: another
/// schema's stays live, and the revoked one keeps its data.
#[test]
fun revoke_leaves_other_attestations_alone() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry, clock) = begin();
    attest(&mut scenario, audit(), subject, Audit { score: 90 }, &clock);
    scenario.next_tx(ALICE);
    attest(&mut scenario, review(), subject, Review { score: 4 }, &clock);

    scenario.next_tx(ALICE);
    let audit_id = ids<Audit>(registry, subject)[0];
    let review_id = ids<Review>(registry, subject)[0];
    revoke(&mut scenario, audit(), subject, audit_id, &clock);

    scenario.next_tx(ALICE);
    // One address, the two schemas told apart by type.
    assert_eq!(ids<Audit>(registry, subject), vector[audit_id]);
    assert_eq!(ids<Review>(registry, subject), vector[review_id]);
    let at = address_of(registry, subject);
    let revoked: Attestation<Audit> = scenario.take_from_address_by_id(at, audit_id);
    assert!(revoked.revoked_at_ms().is_some());
    assert_eq!(revoked.data().score, 90);
    let live: Attestation<Review> = scenario.take_from_address_by_id(at, review_id);
    assert!(live.revoked_at_ms().is_none());
    assert_eq!(live.data().score, 4);
    test_scenario::return_to_address(at, revoked);
    test_scenario::return_to_address(at, live);
    finish(scenario, clock);
}

/// Attesting emits one `Attested<T>` and revoking one `Revoked<T>`, each
/// naming the attestation's subject.
#[test]
fun attest_and_revoke_emit_events() {
    let subject = subject_for(@0xDEAD);
    let (mut scenario, registry, clock) = begin();
    attest(&mut scenario, audit(), subject, Audit { score: 90 }, &clock);
    let attested = event::events_by_type<Attested<Audit>>();
    assert_eq!(attested.length(), 1);
    assert_eq!(attested[0].attested_subject(), subject);
    assert!(event::events_by_type<Revoked<Audit>>().is_empty());
    assert_eq!(scenario.next_tx(ALICE).num_user_events(), 1);

    let id = ids<Audit>(registry, subject)[0];
    revoke(&mut scenario, audit(), subject, id, &clock);
    let revoked = event::events_by_type<Revoked<Audit>>();
    assert_eq!(revoked.length(), 1);
    assert_eq!(revoked[0].revoked_subject(), subject);
    assert!(event::events_by_type<Attested<Audit>>().is_empty());
    assert_eq!(scenario.next_tx(ALICE).num_user_events(), 1);
    finish(scenario, clock);
}
