# Demo fixtures

Move packages that exist only to drive the local end-to-end demo
(`demo/scripts/run-demo.sh`). Unlike `examples/`, nothing here is meant to be reused —
these are throwaway identities and subjects.

## Auditors

`auditor_a/`, `auditor_b/`, and `auditor_c/` are three **independently-published
copies** of `examples/auditor` (the reusable schema), with distinct package
identities:

- **`auditor_a`** — in the demo's trust config (the "trusted" auditor). A copy of
  `examples/auditor` **plus** an added `AuditV2` upgrade — the schema-evolution
  illustration lives here, not in the reference.
- **`auditor_b`** — **not** in the trust config. A plain copy of
  `examples/auditor`. Its `Audit` records are identical in type to Auditor A's
  but anchored to a different package.
- **`auditor_c`** — a second **trusted** auditor (in the trust config). A plain
  copy of `examples/auditor`, created by following that template's onboarding
  guide; its audits surface alongside Auditor A's.

This is the core thing the demo shows: **trust is anchored to package identity,
not to the schema.** Two auditors emit the very same `Attestation<Audit>` type;
a consumer surfaces one and ignores the other purely by package address.

## Subjects

- **`dependency_example/`** — a package that gets audited; a dependency of
  `subject_example`. It's **upgraded to a second version** in the demo: v1 is
  audited but v2 (the latest) is left unaudited, so the mvr Security page shows
  the latest version as unaudited while an older version was audited — the
  security signal that an audit doesn't carry across an upgrade.
- **`subject_example/`** — the package a viewer browses; depends on
  `dependency_example`.

## The scenario

`demo/scripts/run-demo.sh` (via `demo/scripts/demo.sh`) publishes these packages, then has
`auditor_a` and `auditor_c` issue attestations (and `auditor_a` revoke one), plus
one from the untrusted `auditor_b`. Keep this in sync with `demo.sh`.

| Subject | Attestation | Status |
|---|---|---|
| `@demo/dependency` v1 | Audit (Auditor A, no findings) | **Active** |
| `@demo/dependency` v1 | Audit (Auditor C) | **Active** |
| `@demo/dependency` v2 (latest) | *(none)* | — |
| `@demo/subject` | AuditV2 (Auditor A, score 95) | **Active** |
| `@demo/subject` | Audit (Auditor C) | **Active** |
| `@demo/subject` | Audit (Auditor A, v1, superseded) | **Revoked** |
| `@demo/subject` | Audit (Auditor B) | **Active** |
| `@demo/subject` | InternalNote | **Active** |

Attestations come from `auditor_a` and `auditor_c` (both trusted) except the
Auditor B one (untrusted).
"Active"/"Revoked" is the on-chain status — which box (active or revoked) owns it.

**What a consumer sees.** A consumer that trusts `auditor_a` and `auditor_c` but
not `auditor_b` sees, on `@demo/subject`, Auditor A's **`AuditV2` (score 95)** and
Auditor C's **`Audit`**: the v1 `Audit` is revoked, the Auditor B `Audit` is
filtered out by attester *identity* (same type, different package), and the
`InternalNote` has no registered Display.
`@demo/dependency` has two versions — v1 is audited (Active) but v2 (the latest)
is left unaudited — so the Security page shows the latest version with a "no
published audits" warning alongside the audited older version.
Revoked attestations remain readable from each subject's revoked box — a consumer
typically lists them separately so they don't read as endorsements.
