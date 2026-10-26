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

- Registry package:
  `0x754da52dba4429dc141b4298c5afebb4697d7ff74a15580c0f3074f3f33f79e5`
- Shared `Registry`:
  `0x333d2e0d4eba57451e942bfc1ebffd0d4daf599ff719bab556e2882109df4db3`

Mainnet:

- Registry package:
  `0xf918b2fc17085f4e48021be94ee43f9cc4437256acfd085f1e3d1a54d11f6e7b`
- Shared `Registry`:
  `0x86875cdb65149c3a1c9653486c09ef7846a751823bb2a96d434fd01fbd4b052e`

Both deployments use the current revocation model described above. See
[Published.toml](Published.toml) for compiler and publication metadata and
[MAINNET.md](../../MAINNET.md) for mainnet transaction IDs, custody, and pending
MVR setup. The mainnet MVR name is not yet assigned.
