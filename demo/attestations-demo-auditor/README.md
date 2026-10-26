# Attestations Demo Auditor

**This is a demonstration attester, not a real security auditor.** Its
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

### Mainnet

Published as package
`0x70b5189985e476f8f2e6f014ed9e2e6aeee71f4cafb07b768c3a7c7467e0e793`, linked
to the mainnet core registry. Source verification passed. Display registration,
MVR linkage, and example issuance remain pending. See the
[mainnet deployment record](../../MAINNET.md) for capabilities, transaction IDs,
and remaining steps. The demo warning applies on mainnet too.

### Testnet

Published on **testnet** as a fresh package, not an upgrade of the old
`@pkg/attestations-demo-auditor` deployment. Source verification passed, and the
Display is registered with the fields described above.

| Object | ID |
| --- | --- |
| Package | `0x1b3a65bc3eb8c2268329a2e91e3b87fc081516676efa6e3361c0d278782a371a` |
| AuditAdminCap | `0x8bef0e9a5b813dce933c1b149215132d499d34de48718021e923edb421886865` |
| UpgradeCap | `0x33fc7826fb59ed055b4985ee73ff7e3d736958c5be84887ae0b3ba8ba6217ecd` |
| Display | `0x7885a15e1a693cc42863fbab0ea3e487b4e960ed22ebeff310f84884e95892b6` |

Publish transaction: `GcwHLMWYUpdbVZeByDNAXMi4twrGLwXcXLd9drhTpcRz`.
Display registration: `8jEcnR1XTbC3t2ArshaKBYV4dJEC5NVzGeYVnzAJUXFj`.
See [Published.toml](Published.toml) for the compiler and publication metadata.
Do not reuse the old deployment's IDs or move its `attestations-demo-auditor/v1`
source tag. Package publication alone does not update MVR naming or consumer trust.

`Move.toml` uses the local registry package and its committed `Published.toml`
to resolve the selected network's registry without an MVR lookup. `Move.lock`
records the dependency graph; it does not make local source immutable, so verify
the dependency before publishing.

From the repository root:

```sh
bash scripts/check.sh demo/attestations-demo-auditor
bash scripts/check-template.sh
```

[DEPLOYMENT.md](DEPLOYMENT.md) contains the testnet preflight, publishing, MVR
setup, and live/revoked verification steps. Reuse each network's recorded IDs;
do not repeat publication or an already completed Display registration. Further
transactions require separate approval.

## Building your own attester

Use the clean [auditor template](../../examples/auditor/README.md), not this
branded demo. It covers schema customization, capability custody, issuance,
and revocation. See [DESIGN.md](../../DESIGN.md) for the registry model and
[CONVENTIONS.md](../../CONVENTIONS.md) for Display fields.
