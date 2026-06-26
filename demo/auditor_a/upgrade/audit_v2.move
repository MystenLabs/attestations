/// V2 audit schema, introduced in a package *upgrade* of auditor_a.
///
/// This module lives outside `sources/` so it is absent from the initial
/// publish. The publish script copies it into `sources/` only for the
/// upgrade step (see `demo/scripts/test-publish.sh`). As a result `AuditV2`'s
/// defining (origin) package id is the *upgraded* package id — distinct from
/// auditor_a's original publish id — while `attester_of<AuditV2>()` still
/// resolves to the original id. That mismatch is exactly the schema-evolution
/// case the trusted-attestor matching must handle: trusting auditor_a's
/// original id should surface `Attestation<AuditV2>` too.
module auditor_a::audit_v2;

use std::internal;
use std::string::String;
use sui::display_registry::{DisplayRegistry, Display, DisplayCap};
use sui::transfer::Receiving;
use attestations::attestations::{Registry, Box, Attestation};
use auditor_a::audit::AuditAdminCap;

/// V2 audit payload: keeps the numeric `score`, plus the description and
/// publish-date the reference schema carries.
public struct AuditV2 has store, drop {
    /// Human-readable summary of the audit, surfaced via the `description`
    /// presentation field.
    description: String,
    /// URL of the full audit report (surfaced via the `link` convention).
    report_url: String,
    /// Report publication date (ms since epoch), surfaced via the
    /// `publish_date` convention.
    publish_date_ms: u64,
    /// Numeric audit score, surfaced via the custom `score` field.
    score: u8,
}

/// One-shot setup: register the append-only `Display<Attestation<AuditV2>>`
/// with the full presentation set plus the custom `score` field. The
/// `methodology` field is added later via `add_audit_v2_methodology_display`,
/// to exercise `add_display_field`.
public fun register_audit_v2_display(
    registry: &Registry,
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    registry.register_display(
        display_registry,
        internal::permit<AuditV2>(),
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"link".to_string(),
            b"image_url".to_string(),
            b"publish_date".to_string(),
            b"score".to_string(),
        ],
        vector[
            b"Audit attestation (v2)".to_string(),
            b"{data.description}".to_string(),
            b"{data.report_url}".to_string(),
            b"https://example.com/auditor-icon.svg".to_string(),
            b"{data.publish_date_ms:ts}".to_string(),
            b"{data.score}/100".to_string(),
        ],
        ctx,
    );
}

/// Append a static `methodology` field to the already-published
/// `Display<Attestation<AuditV2>>` — a worked example of `add_display_field`.
/// Gated by `Permit<AuditV2>`; `rcv` is the `DisplayCap` that
/// `register_audit_v2_display` parked on the Registry. Append-only: it can't
/// alter or remove existing fields.
public fun add_audit_v2_methodology_display(
    registry: &mut Registry,
    display: &mut Display<Attestation<AuditV2>>,
    rcv: Receiving<DisplayCap<Attestation<AuditV2>>>,
) {
    registry.add_display_field(
        display,
        internal::permit<AuditV2>(),
        rcv,
        vector[b"methodology".to_string()],
        vector[b"https://auditor-a.example/methodology".to_string()],
    );
}

/// Issue an AuditV2 attestation about `subject`. Revocable via
/// `revoke_audit_v2` (same `AuditAdminCap` as v1 audits).
public fun attest_audit_v2(
    _: &AuditAdminCap,
    registry: &Registry,
    subject: ID,
    description: String,
    report_url: String,
    publish_date_ms: u64,
    score: u8,
    ctx: &mut TxContext,
) {
    registry.attest(
        internal::permit<AuditV2>(),
        subject,
        AuditV2 { description, report_url, publish_date_ms, score },
        ctx,
    );
}

/// Revoke an `Attestation<AuditV2>`, reusing the auditor_a's `AuditAdminCap`
/// (one authority covers every audit type this package defines).
public fun revoke_audit_v2(
    _: &AuditAdminCap,
    box: &mut Box,
    rcv: Receiving<Attestation<AuditV2>>,
) {
    box.revoke(internal::permit<AuditV2>(), rcv);
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
public fun attest_internal_note(registry: &Registry, subject: ID, text: String, ctx: &mut TxContext) {
    registry.attest(
        internal::permit<InternalNote>(),
        subject,
        InternalNote { text },
        ctx,
    );
}
