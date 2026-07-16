# attestations

The on-chain core of a typed attestation registry for Sui: a shared `Registry`,
permanent `Attestation<T>` objects, and the `attest` / `revoke` /
`register_display` entry points.

## What it provides

- **`Attestation<T>`** — a permanent, `key`-only object carrying a typed payload
  `T` and the `subject` it is about. The *attester* recorded on it is `T`'s
  defining package (`type_name::original_id<T>()`), not the transaction signer —
  so trust is anchored to package identity.
- **`Registry`** — a shared singleton, created at publish, under which every
  subject's attestation **boxes** are derived.
- **`Permit<T>` gating** — `attest`, `revoke`, and `register_display` are each
  authorized by a `Permit<T>`, which only `T`'s defining module can mint. A
  schema package therefore sets its own attestation and revocation policy.
- **Per-subject boxes** — each subject has an *active* and a *revoked* box; an
  attestation's status is simply which box owns it (transfer-to-object). Off-chain
  consumers read a subject's live attestations with one type-filtered query and
  no per-object status check.

## Using it

Define a schema package that owns a `store` type `T` and exposes wrappers that
mint a `Permit<T>` and call into this package. See
[`examples/auditor`](../../examples/auditor) for a complete, copyable template
and a walkthrough for a new attester.

## More

- [`DESIGN.md`](../../DESIGN.md) — why the on-chain design is shaped this way.
- [`CONVENTIONS.md`](../../CONVENTIONS.md) — the Display-field conventions that
  consumers rely on.
