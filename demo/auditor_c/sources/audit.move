module auditor_c::audit;

use std::internal;
use std::string::String;
use sui::display_registry::DisplayRegistry;
use sui::transfer::Receiving;
use attestations::attestations::{Registry, Box, Attestation};

/// Audit attestation payload. Lifecycle for `Attestation<Audit>` is controlled by the `AuditAdminCap`
public struct Audit has store, drop {
    /// Human-readable summary of the audit, surfaced via the `description`
    /// presentation field.
    description: String,
    /// URL of the full audit report (surfaced via the `link` convention).
    report_url: String,
    /// Report publication date (ms since epoch), surfaced via the
    /// `published_at` convention.
    published_at_ms: u64,
}

/// Single-party authority to *control* this auditor's attestations: whoever
/// holds this cap can both issue and revoke any `Attestation<Audit>`. Created
/// once at publish and transferred to the publisher.
public struct AuditAdminCap has key, store {
    id: UID,
}

/// Mint the auditor's `AuditAdminCap` at publish and hand it to the publisher.
fun init(ctx: &mut TxContext) {
    transfer::transfer(AuditAdminCap { id: object::new(ctx) }, ctx.sender());
}

/// One-shot setup: register the append-only `Display<Attestation<Audit>>` with
/// the full presentation set (name, description, link, image, publish date).
/// Should be called once shortly after publish; aborts on second call
/// (V2 enforcement via `display_registry`).
entry fun register_audit_display(
    registry: &Registry,
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    registry.register_display(
        display_registry,
        internal::permit<Audit>(),
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"link".to_string(),
            b"image_url".to_string(),
            b"published_at".to_string(),
        ],
        vector[
            b"Auditor C audit".to_string(),
            b"{data.description}".to_string(),
            b"{data.report_url}".to_string(),
            b"https://raw.githubusercontent.com/mdgeorge4153/sui-attestation-registry/mdgeorge/attest-positive/demo/auditor_c/icon.svg".to_string(),
            b"{data.published_at_ms:ts}".to_string(),
        ],
        ctx,
    );
}

/// Issue an `Attestation<Audit>` about `subject`. Gated by the `AuditAdminCap`,
/// the single authority over this auditor's attestations.
public fun attest_audit(
    _: &AuditAdminCap,
    registry: &Registry,
    subject: ID,
    description: String,
    report_url: String,
    published_at_ms: u64,
    ctx: &mut TxContext,
) {
    registry.attest(
        internal::permit<Audit>(),
        subject,
        Audit { description, report_url, published_at_ms },
        ctx,
    );
}

/// Revoke an `Attestation<Audit>` that is owned by `box`, which must be the non-revoked box that owns the attestation indicated by `rcv`.
/// Gated by the `AuditAdminCap`.
public fun revoke_audit(
    _: &AuditAdminCap,
    box: &mut Box,
    rcv: Receiving<Attestation<Audit>>,
) {
    box.revoke(internal::permit<Audit>(), rcv);
}

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AuditAdminCap {
    AuditAdminCap { id: object::new(ctx) }
}
