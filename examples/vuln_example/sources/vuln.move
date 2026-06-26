/// Example of a "negative" attestation schema: each `Attestation<Vulnerability>`
/// asserts that the subject has a known vulnerability. Consumers surface it via
/// the `polarity` convention (negative); an effective Vulnerability can also
/// propagate to the subject's dependents.
module vuln_example::vuln;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use sui::transfer::Receiving;
use attestation_registry::attestation_registry::{Self, Registry, Box, Attestation};

#[error(code = 0)]
const EVulnRevokeMismatch: vector<u8> =
    b"VulnRevokeCap doesn't match the attestation being revoked";

/// Per-attestation bearer cap, reconstructed schema-side. Holding it *is* the
/// authority to revoke the one `Attestation<Vulnerability>` it names — the
/// same model the base registry used to provide built-in, here expressed in
/// the schema. `attestation_id` binds the cap to a specific attestation; the
/// guard in `revoke_vuln` enforces the binding.
public struct VulnRevokeCap has key, store {
    id: UID,
    attestation_id: ID,
}

/// Vulnerability attestation payload. Defined here so vuln_example is the
/// `Permit<Vulnerability>` minting authority — the recorded attester for
/// every `Attestation<Vulnerability>` is vuln_example's published address.
public struct Vulnerability has store, drop {
    /// Severity score 0–10 (CVSS-style).
    severity: u8,
    /// CVE identifier (e.g. "CVE-2026-1234").
    cve_id: String,
    /// Short human-readable description.
    description: String,
    /// URL of the advisory / full write-up (surfaced via the `link` convention).
    advisory_url: String,
}

/// One-shot setup: register the immutable `Display<Attestation<Vulnerability>>`.
public fun register_vuln_display(
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    attestation_registry::register_display<Vulnerability>(
        display_registry,
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"severity".to_string(),
            b"cve_id".to_string(),
            b"link".to_string(),
            b"polarity".to_string(),
        ],
        vector[
            b"Vulnerability disclosure".to_string(),
            b"{data.description}".to_string(),
            b"{data.severity}".to_string(),
            b"{data.cve_id}".to_string(),
            b"{data.advisory_url}".to_string(),
            b"negative".to_string(),
        ],
        std::internal::permit<Vulnerability>(),
        ctx,
    );
}

/// Issue a Vulnerability attestation about `subject`. Returns a
/// `VulnRevokeCap` bound to the new attestation — vulnerability attestations
/// are typically revoked (via `revoke_vuln`) when the issue is patched.
public fun attest_vuln(
    registry: &Registry,
    subject: ID,
    severity: u8,
    cve_id: String,
    description: String,
    advisory_url: String,
    ctx: &mut TxContext,
): VulnRevokeCap {
    let attestation_id = attestation_registry::attest<Vulnerability>(
        registry,
        subject,
        Vulnerability { severity, cve_id, description, advisory_url },
        ctx,
    );
    VulnRevokeCap { id: object::new(ctx), attestation_id }
}

/// Revoke the `Attestation<Vulnerability>` named by `cap`. Aborts
/// `EVulnRevokeMismatch` if `rcv` references a different attestation —
/// `transfer::receiving_object_id` lets the schema reconstruct the exact
/// per-attestation binding the base registry's bearer cap used to enforce.
public fun revoke_vuln(
    cap: VulnRevokeCap,
    box: &mut Box,
    rcv: Receiving<Attestation<Vulnerability>>,
) {
    let VulnRevokeCap { id, attestation_id } = cap;
    id.delete();
    assert!(transfer::receiving_object_id(&rcv) == attestation_id, EVulnRevokeMismatch);
    attestation_registry::revoke<Vulnerability>(box, std::internal::permit<Vulnerability>(), rcv);
}

public fun severity(self: &Vulnerability): u8 { self.severity }
public fun cve_id(self: &Vulnerability): &String { &self.cve_id }
public fun description(self: &Vulnerability): &String { &self.description }

#[test_only]
public fun cap_attestation_id(cap: &VulnRevokeCap): ID { cap.attestation_id }
