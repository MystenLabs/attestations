module auditor_c::audit;

use attestations::attestations::{Registry, Attestation};
use std::internal;
use std::string::String;
use sui::clock::Clock;
use sui::display_registry::DisplayRegistry;
use sui::transfer::Receiving;

/// Audit attestation payload. Lifecycle for `Attestation<Audit>` is controlled by the `AuditAdminCap`
public struct Audit has drop, store {
    /// Human-readable summary of the audit, surfaced via the `description`
    /// presentation field.
    description: String,
    /// URL of the full audit report (surfaced via the `link` convention).
    report_url: String,
    /// Digest of the report at `report_url`, surfaced via the `link_hash`
    /// convention (e.g. `sha256:…`). `none` when no digest was recorded.
    report_hash: Option<String>,
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
/// the full presentation set (name, description, link, link hash, image,
/// publish date). Should be called once shortly after publish; aborts on second
/// call (V2 enforcement via `display_registry`).
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
            b"link_hash".to_string(),
            b"image_url".to_string(),
            b"published_at".to_string(),
        ],
        vector[
            b"Auditor C audit".to_string(),
            b"{data.description}".to_string(),
            b"{data.report_url}".to_string(),
            b"{data.report_hash}".to_string(),
            b"https://raw.githubusercontent.com/MystenLabs/attestations/demo-latest/demo/auditor_c/icon.svg".to_string(),
            b"{data.published_at_ms:ts}".to_string(),
        ],
        ctx,
    );
}

/// Issue an `Attestation<Audit>` about `subject`. Gated by the `AuditAdminCap`,
/// the single authority over this auditor's attestations. `report_hash`
/// optionally pins the digest of the report at `report_url` (the `link_hash`
/// convention); pass `none` to omit it.
public fun attest_audit(
    _: &AuditAdminCap,
    registry: &Registry,
    subject: ID,
    description: String,
    report_url: String,
    report_hash: Option<String>,
    published_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    registry.attest(
        internal::permit<Audit>(),
        subject,
        Audit { description, report_url, report_hash, published_at_ms },
        clock,
        ctx,
    );
}

/// Revoke the `Attestation<Audit>` indicated by `rcv`, which must be one of
/// `subject`'s attestations. Gated by the `AuditAdminCap`.
public fun revoke_audit(
    _: &AuditAdminCap,
    registry: &mut Registry,
    subject: ID,
    rcv: Receiving<Attestation<Audit>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    registry.revoke(internal::permit<Audit>(), subject, rcv, clock, ctx);
}

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AuditAdminCap {
    AuditAdminCap { id: object::new(ctx) }
}
