/// A fully-formed attester package — it defines a schema and registers a
/// Display — that is simply NOT in a consumer's trusted set. Used as negative
/// test data: a trust consumer must filter out `Attestation<Untrusted>` by the
/// attester package not being whitelisted, even though the attestation is
/// otherwise well-formed and displayable.
module untrusted_example::untrusted;

use std::string::String;
use sui::display_registry::DisplayRegistry;
use attestation_registry::attestation_registry::{Self, Registry};

/// Payload of an attestation from an untrusted attester.
public struct Untrusted has store, drop {
    note: String,
}

/// Register the immutable `Display<Attestation<Untrusted>>` so the attestation
/// is well-formed — the consumer must reject it on the attester, not on a
/// missing Display.
public fun register_untrusted_display(
    display_registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
) {
    attestation_registry::register_display<Untrusted>(
        display_registry,
        vector[b"name".to_string(), b"description".to_string()],
        vector[
            b"Untrusted attestation".to_string(),
            b"{data.note}".to_string(),
        ],
        std::internal::permit<Untrusted>(),
        ctx,
    );
}

/// Issue an Untrusted attestation about `subject` (negative test data;
/// unrevocable — no revoke wrapper exposed).
public fun attest_untrusted(
    registry: &Registry,
    subject: ID,
    note: String,
    ctx: &mut TxContext,
) {
    attestation_registry::attest<Untrusted>(
        registry,
        subject,
        Untrusted { note },
        ctx,
    );
}
