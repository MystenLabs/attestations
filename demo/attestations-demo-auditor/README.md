# Attestations Demo Auditor

**This is a demonstration attester, not a real security auditor.** It exists to
populate the [Move Registry](https://www.moveregistry.com) attestations demo on
**testnet** with example audit attestations, so the registry's trust signals
have something to show. Its audits are illustrative and carry no assurance.

The package is published verbatim from the registry's
[`examples/auditor`](https://github.com/MystenLabs/attestations/tree/main/examples/auditor)
template — the copyable starting point for building a real attester. This
directory is that copy, kept as the demo auditor's on-chain source of record (see
`Published.toml`).

## What it does

`sources/audit.move` defines an `Audit` attestation type and the `AuditAdminCap`
that authorizes issuing and revoking it. The attester recorded on every
`Attestation<Audit>` is *this package's on-chain identity*, so trust flows from
whoever controls the package — not from the transaction signer.

In the demo it issues a handful of `Audit` attestations about real testnet
packages. Those surface on each subject's **Security** tab in the registry UI,
linked back to this page.

## Building your own attester

Don't copy *this* — copy the clean template it came from:
[`examples/auditor`](https://github.com/MystenLabs/attestations/tree/main/examples/auditor),
whose README walks through customizing the package, publishing it, securing your
capabilities in a multisig, and issuing (and revoking) real reports.

## Learn more

- Attester-identity model and registry design —
  [`DESIGN.md`](https://github.com/MystenLabs/attestations/blob/main/DESIGN.md).
- Display field conventions (`name`, `description`, `image_url`, `link`,
  `published_at`) —
  [`CONVENTIONS.md`](https://github.com/MystenLabs/attestations/blob/main/CONVENTIONS.md).
