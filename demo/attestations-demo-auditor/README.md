# Attestations Demo Auditor

**This is a demonstration attester, not a real security auditor.** It exists to
populate the [Move Registry](https://www.moveregistry.com) attestations demo on
**testnet** with example audit attestations, so the registry's trust signals
have something to show. Its audits are illustrative and carry no assurance.

## Our attestations

In the demo it issues a handful of `Audit` attestations about real testnet
packages. Those surface on each subject's **Security** tab in the registry UI,
linked back to this page.

The issued attestations are arbitrary and indicate nothing about the packages
that they are issued on.

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
