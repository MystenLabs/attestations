/// V2 audit schema, introduced in a package *upgrade* of audit_example.
///
/// This module lives outside `sources/` so it is absent from the initial
/// publish. The publish script copies it into `sources/` only for the
/// upgrade step (see `scripts/test-publish.sh`). As a result `AuditV2`'s
/// defining (origin) package id is the *upgraded* package id — distinct from
/// audit_example's original publish id — while `attester_of<AuditV2>()` still
/// resolves to the original id. That mismatch is exactly the schema-evolution
/// case the trusted-attestor matching must handle: trusting audit_example's
/// original id should surface `Attestation<AuditV2>` too.
module audit_example::audit_v2;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};
use audit_example::audit::AuditAdminCap;

/// V2 audit payload: adds a report link.
public struct AuditV2 has store, drop {
    score: u8,
    /// URL of the full audit report (surfaced via the `link` convention).
    report_url: String,
}

/// One-shot setup: register the immutable `Display<Attestation<AuditV2>>`,
/// including the `link` convention field.
public fun register_audit_v2_display(
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    attestation_registry::register_display<AuditV2>(
        display_registry,
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"link".to_string(),
            b"polarity".to_string(),
        ],
        vector[
            b"Audit attestation (v2)".to_string(),
            b"Score: {data.score}/100".to_string(),
            b"{data.report_url}".to_string(),
            b"positive".to_string(),
        ],
        std::internal::permit<AuditV2>(),
        ctx,
    );
}

/// Issue an AuditV2 attestation about `subject`. Revocable via
/// `revoke_audit_v2` (same `AuditAdminCap` as v1 audits).
public fun attest_audit_v2(
    registry: &Registry,
    subject: ID,
    score: u8,
    report_url: String,
    ctx: &mut TxContext,
) {
    attestation_registry::attest<AuditV2>(
        registry,
        subject,
        AuditV2 { score, report_url },
        ctx,
    );
}

/// Revoke an `Attestation<AuditV2>`, reusing the auditor's `AuditAdminCap`
/// (one authority covers every audit type this package defines).
public fun revoke_audit_v2(
    _: &AuditAdminCap,
    box: &mut Box,
    rcv: Receiving<Attestation<AuditV2>>,
) {
    attestation_registry::revoke<AuditV2>(box, std::internal::permit<AuditV2>(), rcv);
}

/// The numeric audit score.
public fun score(self: &AuditV2): u8 { self.score }

/// The audit report URL.
public fun report_url(self: &AuditV2): &String { &self.report_url }

// === Undisplayed schema (negative test data) ===
//
// A second schema in this (trusted) package that intentionally has NO
// registered Display. A trust consumer's Display-gate must filter out
// `Attestation<InternalNote>` even though its attester package is trusted.

public struct InternalNote has store, drop {
    text: String,
}

/// Issue an InternalNote attestation. No Display is registered for
/// `Attestation<InternalNote>`, so Display-gating consumers ignore it.
/// Unrevocable — this schema exposes no revoke wrapper (negative test data).
public fun attest_internal_note(
    registry: &Registry,
    subject: ID,
    text: String,
    ctx: &mut TxContext,
) {
    attestation_registry::attest<InternalNote>(
        registry,
        subject,
        InternalNote { text },
        ctx,
    );
}
