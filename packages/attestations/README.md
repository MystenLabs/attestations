# Attestations

This package provides the onchain core for typed, verifiable attestations on
Sui: a way for one package to make a durable, public claim about a subject — an
audit of another package, a certification of an object, any statement worth
recording onchain — that anyone can read back directly from the chain.

The central type is `Attestation<T>`, a permanent object carrying a typed
payload `T` and the `subject` it describes. The attester recorded on it is the
package that defined `T`, determined at mint time rather than taken from the
transaction signer. Trust is anchored to package identity: an audit is credible
because its type comes from the auditor's own published package, so no other
party can forge one in their name.

## How it works

- **`Attestation<T>` is permanent and `key`-only.** No outside caller can
  transfer, wrap, or destroy one; the only ways to move it are this package's
  `attest` and `revoke`.
- **A `Permit<T>` gates every action.** `attest`, `revoke`, and
  `register_display` each require a `Permit<T>`, and Move lets only `T`'s
  defining package mint one. Each schema package therefore sets its own policy
  for who may issue and revoke — an admin cap, a per-attestation cap, a
  multisig, or no one at all.
- **A shared `Registry`** is created when the package is published. Each
  subject's attestations live in per-subject boxes derived from it, at addresses
  anyone can compute offchain from the registry and subject ids.
- **Revocation is a location, not a flag.** Every subject has an active box and
  a revoked box, and an attestation's status is simply which one holds it. A
  consumer reads a subject's live attestations with a single type-filtered query
  and no per-object status check, which keeps enumeration cheap for indexers.

## Using it

You don't attest against this package directly. You write a small schema package
that defines your claim type `T` and exposes wrappers that mint a `Permit<T>`
and call in. The `examples/auditor` package in this repository is a complete,
copyable template, with a walkthrough for standing up a new attester end to end.

The repository also carries the design rationale (see DESIGN.md) and the
Display-field conventions consumers rely on for cross-cutting behavior like
expiration (see CONVENTIONS.md).
