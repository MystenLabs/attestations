module audit_example::audit;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};

/// Audit attestation payload. Defined here so audit_example is the
/// `Permit<Audit>` minting authority and the recorded attester for every
/// `Attestation<Audit>` is audit_example's published address.
public struct Audit has store, drop {
    score: u8,
    /// URL of the full audit report (surfaced via the `link` convention).
    report_url: String,
}

/// Single-party revocation authority: whoever holds this cap can revoke *any*
/// `Attestation<Audit>` (and `AuditV2`) from this auditor. Created once at
/// publish and transferred to the publisher. This is one revocation-policy
/// choice among many — the base registry prescribes none; each schema picks
/// its own and supplies the `Permit` the registry's `revoke` requires.
public struct AuditAdminCap has key, store {
    id: UID,
}

/// Mint the auditor's `AuditAdminCap` at publish and hand it to the publisher.
fun init(ctx: &mut TxContext) {
    transfer::transfer(AuditAdminCap { id: object::new(ctx) }, ctx.sender());
}

/// One-shot setup: register the immutable `Display<Attestation<Audit>>`.
/// Should be called once shortly after publish; aborts on second call
/// (V2 enforcement via `display_registry`).
public fun register_audit_display(
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    attestation_registry::register_display<Audit>(
        display_registry,
        vector[
            name_field(),
            description_field(),
            b"link".to_string(),
            b"polarity".to_string(),
        ],
        vector[
            b"Audit attestation".to_string(),
            b"Score: {data.score}/100".to_string(),
            b"{data.report_url}".to_string(),
            b"positive".to_string(),
        ],
        std::internal::permit<Audit>(),
        ctx,
    );
}

/// Issue an Audit attestation about `subject`. Revocable via `revoke_audit`
/// (the returned attestation id is unused here — the `AuditAdminCap` is the
/// authority, not a per-attestation cap).
public fun attest_audit(
    registry: &Registry,
    subject: ID,
    score: u8,
    report_url: String,
    ctx: &mut TxContext,
) {
    attestation_registry::attest<Audit>(
        registry,
        subject,
        Audit { score, report_url },
        ctx,
    );
}

/// Revoke an `Attestation<Audit>`. Single-party: any holder of the
/// `AuditAdminCap` can revoke any audit. Mints the `Permit<Audit>` the
/// registry's `revoke` requires (only this module can).
public fun revoke_audit(
    _: &AuditAdminCap,
    box: &mut Box,
    rcv: Receiving<Attestation<Audit>>,
) {
    attestation_registry::revoke<Audit>(box, std::internal::permit<Audit>(), rcv);
}

/// The numeric audit score.
public fun score(self: &Audit): u8 { self.score }

fun name_field(): String { b"name".to_string() }
fun description_field(): String { b"description".to_string() }

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AuditAdminCap {
    AuditAdminCap { id: object::new(ctx) }
}
