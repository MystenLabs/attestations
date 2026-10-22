# Attestations Demo Auditor

**This is a demonstration attester, not a real security auditor.** It exists to
populate the [Move Registry](https://www.moveregistry.com) attestations demo on
**testnet** with example audit attestations, so the registry's trust signals
have something to show. Its audits are illustrative and carry no assurance.

## Our attestations

After deployment, this package will issue `Audit` attestations about testnet
packages for display on each subject's **Security** tab in the registry UI.

The issued attestations are arbitrary and indicate nothing about the packages
that they are issued on.

## Deployment status

This source is prepared for a **fresh deployment** against the current registry.
It does not match the previously published demo auditor and is not an upgrade
of that package. The old `Published.toml` and `Move.lock` have been removed.

For now, `Move.toml` depends on `../../packages/attestations`, so builds use this
checkout rather than the previously published registry. From the repository root:

```sh
bash scripts/check.sh demo/attestations-demo-auditor
bash scripts/check-template.sh
```

Leave any generated `Move.lock` uncommitted until deployment preparation is
complete. Before publishing this demo, publish the new registry on testnet
and confirm the demo dependency resolves to that deployment. Then regenerate
and commit `Move.lock`, publish this package as a new package, and commit its new
`Published.toml`. Register the audit Display and update the Move Registry demo's
package references and source metadata to the new deployment. Do not reuse the
old package ID, capabilities, or source tag.

## Building your own attester

Copy the clean template rather than this demo:
[`examples/auditor`](https://github.com/MystenLabs/attestations/tree/main/examples/auditor),
whose README walks through customizing the package, publishing it, securing your
capabilities in a multisig, and issuing (and revoking) real reports.

## Learn more

- Attester-identity model and registry design:
  [`DESIGN.md`](https://github.com/MystenLabs/attestations/blob/main/DESIGN.md).
- Display field conventions (`name`, `description`, `image_url`, `link`,
  `link_hash`, `published_at`):
  [`CONVENTIONS.md`](https://github.com/MystenLabs/attestations/blob/main/CONVENTIONS.md).
