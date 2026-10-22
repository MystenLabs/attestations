# Attestations

This package provides the onchain core for typed, verifiable attestations on
Sui: a way for one package to make a durable, public claim about a subject. For
example, this package can be used to add audit reports to a package, KYC data
to an account, or even to issue statements about packages on other chains.

The central type is `Attestation<T>`, a permanent object carrying a typed
payload `T` and the `subject` it describes. The attester recorded on it is the
package that defined `T`, determined at mint time rather than taken from the
transaction signer. Trust is anchored to package identity: an audit is credible
because its type comes from the auditor's own published package, so no other
party can forge one in their name.

## How it works

- **`Attestation<T>` is permanent and `key`-only.** No outside caller can
  transfer, wrap, or destroy one; the only ways to move it are this package's
  `attest` and `revoke` functions.
- **A `Permit<T>` gates every action.** `attest`, `revoke`, and
  `register_display` each require a `Permit<T>`, and Move lets only `T`'s
  defining package mint one. Each schema package therefore sets its own policy
  for who may issue and revoke — an admin cap, a per-attestation cap, a
  multisig, or no one at all.
- **A shared `Registry`** is created when the package is published. Each
  subject's attestations live at an address derived from it, which anyone can
  compute offchain from the registry and subject ids. `attest` takes
  `&Registry`, so every attestation is transferred to an address that this
  registry's `revoke` can receive from.
- **Revocation is a field.** `revoke` sets an attestation's `revoked_at_ms` and
  leaves the attestation at its subject's address. A consumer reads a subject's
  attestations with a single type-filtered query and checks `revoked_at_ms` on
  each.

## Reading attestations

The layout is built so a consumer can find a subject's attestations in one query,
with no index to maintain. Every subject's attestations of type `T` live at an
address you derive yourself from the registry and the subject:

```
address = derive_address(registry, subject)
```

List the objects owned by that address, filtered to `Attestation<T>`, and you
have the subject's attestations. Revoked ones are there too: an attestation is
live while its `revoked_at_ms` is none.

Deriving the address means reproducing Sui's derived-object derivation, with the
subject's `ID` as the key (type `0x2::object::ID`), so in practice you'll want a
small helper rather than a shell one-liner. `examples/auditor` shows a worked
GraphQL query against the attestation type, including how to read the rendered
Display fields.

## Creating attestations

You don't attest against this package directly. You write a small schema package
that defines your claim type `T` and exposes wrappers that mint a `Permit<T>`
and call in. The `examples/auditor` package in this repository is a complete,
copyable template, with a walkthrough for standing up a new attester end to end.

The repository also carries the design rationale (see DESIGN.md) and the
Display-field conventions consumers rely on for cross-cutting behavior like
expiration (see CONVENTIONS.md).

## Deployments

Testnet:

- registry package —
  `0x6e0e1141d77448253ab434b008a01259e81c5c31bd1cdac8922a5256da690c09`
  (defines the `Attestation<T>` and `BoxKey` types)
- `Registry` object —
  `0x5a8a789c0385d5e891519612a7d3d8ab36f1d9fc03d63cdabf1cefb3d848b568`
  (the parent every box address is derived from)

This testnet deployment predates the code in this directory: its `attest` takes
the registry's bare id, and its `revoke` moves an attestation to a second derived
address instead of setting `revoked_at_ms`. It will be replaced by a fresh
publish.

Not yet published on mainnet.
