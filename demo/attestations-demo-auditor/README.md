# Attestations Demo Auditor

**This is a demonstration attester, not a real security auditor.** Its testnet
attestations are examples for [Move Registry](https://www.moveregistry.com).
They provide no security assurance about their subjects.

## What consumers see

Each `Attestation<Audit>` carries a description, report link, optional report
hash, and publication date. Its Display identifies it as
**Demo audit (no security assurance)** and prefixes every description with
**DEMO ONLY - no security assurance.** The project link points to this
repository; the demo does not supply a brand image.

The `AuditAdminCap` authorizes issuance and revocation. Revocation sets
`revoked_at_ms` and leaves the claim readable. A consumer must check that field
and independently configure which attester package identities it trusts.

## Deployment status

This source is prepared for a **fresh testnet deployment**, not an upgrade of
the old `@pkg/attestations-demo-auditor` package. It has not been published yet.
Do not reuse the old package ID, capabilities, or `attestations-demo-auditor/v1`
source tag.

`Move.toml` uses the local registry package and its committed `Published.toml`
to resolve the new testnet registry. This avoids waiting for the
`@mysten/attestations` name update. `Move.lock` records the dependency graph;
it does not make local source immutable, so verify the dependency before publishing.

From the repository root:

```sh
bash scripts/check.sh demo/attestations-demo-auditor
bash scripts/check-template.sh
```

[DEPLOYMENT.md](DEPLOYMENT.md) contains the preflight, publishing, MVR setup,
and live/revoked verification steps. Publishing requires separate approval.

## Building your own attester

Use the clean [auditor template](../../examples/auditor/README.md), not this
branded demo. It covers schema customization, capability custody, issuance,
and revocation. See [DESIGN.md](../../DESIGN.md) for the registry model and
[CONVENTIONS.md](../../CONVENTIONS.md) for Display fields.
