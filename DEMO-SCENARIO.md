# Demo scenario

The attestation data created by `ts/demo/demo.ts` (run via
`scripts/run-demo.sh`), for use with the MVR integration. Keep this in sync
with `demo.ts`.

## Packages

| Package | Role | Schemas |
|---|---|---|
| `attestation_registry` | the registry (shared `Registry` singleton) | — |
| `audit_example` | trusted attester | `Audit` (v1); `AuditV2`, `InternalNote` (added in a v2 **upgrade**) |
| `untrusted_example` | attester **not** in the trusted set | `Untrusted` |
| `dependency_example` | subject; dependency of `subject_example` | — |
| `subject_example` | the browsed subject; depends on `dependency_example` | — |

Trusted attesters (whitelist): `audit_example` only. Its trust covers both its
original id (the `Audit` type) and its upgraded id (`AuditV2`) — the
schema-evolution case.

> Planned (fast-follow, not in this positive MVP): a `vuln_example` "negative"
> schema whose effective vulnerability disclosures propagate from a dependency
> to its dependents.

## Attestations

Every attestation is issued by `audit_example` except where noted. Revocation
moves an attestation out of its subject's active box into the revoked sink.

| Subject | Attestation | Status | Why |
|---|---|---|---|
| `@demo/dependency` | Audit (score 90) | **Revoked** | revoked at the end of the demo |
| `@demo/subject` | AuditV2 (score 95) | **Active** | the live signal |
| `@demo/subject` | Audit (score 88, v1) | **Revoked** | revoked at the end of the demo |
| `@demo/subject` | Untrusted | **Filtered out** | attester not whitelisted (`untrusted_example`) |
| `@demo/subject` | InternalNote | **Filtered out** | no registered Display |

## Expected Security tabs

Attester display name comes from the MVR trust config: `audit_example` →
"Example Auditor".

**`@demo/subject`** — active box: `AuditV2`; revoked sink: the v1 `Audit`.

- Tab badge: **✓ 1** (the live `AuditV2`).
- **Audits**: *Audit attestation (v2)* — by Example Auditor.
- **Revoked:** Example Auditor (Audit attestation) — the v1 audit, listed
  separately so it doesn't read as an endorsement.
- Not shown: the Untrusted and InternalNote attestations.

**`@demo/dependency`** — active box: empty; revoked sink: its `Audit`.

- Tab badge: none (no live attestations).
- **Warning header:** "This package has no active attestations published on
  MVR — it may not have been audited."
- **Revoked:** Example Auditor (Audit attestation).

The auditor's own page has an **Issued** tab listing every attestation
`audit_example` has signed, with revoked ones in a separate "Revoked" section.
