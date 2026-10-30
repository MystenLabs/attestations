# Mainnet deployment

The core attestation registry and demonstration auditor are published on Sui
mainnet (`35834a8a`), source-verified, and named in MVR. The demo's Display is
registered, and it has issued two example claims: one live, one revoked. The
demo provides no security assurance and must not be presented as a real
security auditor.

## Core registry

MVR name: `@mysten/attestations`. Package path:
[`packages/attestations`](packages/attestations).

| Object | ID |
| --- | --- |
| Package | `0xf918b2fc17085f4e48021be94ee43f9cc4437256acfd085f1e3d1a54d11f6e7b` |
| Shared Registry | `0x86875cdb65149c3a1c9653486c09ef7846a751823bb2a96d434fd01fbd4b052e` |
| UpgradeCap | `0xaad2df66d3540603774f4d37b02efd14615b0a6eba801dec2227f88fbba06b1b` |
| PackageInfo | `0xbc6e8865a46ceeec45409bf33cc9b0acafcbd8f21e981dcdfd348c829bfbddf3` |
| AppCap | `0x09f049ad100e970f5b32124108af00ee9a554f132cefee0bcdaae18734a21cc9` |

| Transaction | Digest | Charge (SUI) |
| --- | --- | --- |
| Publish | `8FNfq19cDWQy6sWEGDUWH5toyUzdKREkjesM97eH4yo7` | 0.024184400 |
| UpgradeCap transfer to custody | `2s5FvGdva73xuCxv1KKE8yVfuUGRSnfKUmos9wyHRtAd` | 0.000100163 |
| PackageInfo, source metadata, name binding | `GUVQmQzNo5wXkg6HSn9drUt4aLeDVFg99hz6JEPtHouB` | 0.006021830 |

## Demonstration auditor

MVR name: `@pkg/attestations-demo`. Package path:
[`demo/attestations-demo-auditor`](demo/attestations-demo-auditor). This
package links to the mainnet core above, not the testnet registry.

| Object | ID |
| --- | --- |
| Package | `0x70b5189985e476f8f2e6f014ed9e2e6aeee71f4cafb07b768c3a7c7467e0e793` |
| AuditAdminCap | `0xbfe4d979dd69c6cda1928c31455be7804f057df0ff04789bc7d95d129dd5ed8c` |
| UpgradeCap | `0x87e04d36379c076abd1a3a1568ed662916e294ad2927c98aa34696dfb521e570` |
| PackageInfo | `0xedfa1ec9ac857adf6bc147107c2805cb9da25dc019240215c75b885941114b67` |
| AppCap | `0x3e37d6069ae732282ddc211c22f3c0d83169244fa74e9cac91b8a454a5c2104b` |
| Display | `0x979b540f9eeb84d99da4ddce1c0526babf1e0c2df40f07f84bc2f3890d840bb7` |

The Display's DisplayCap,
`0x33e48fe11dee3174439832bf1678f4d6de23c51313cd748b60469c7ece32f9da`, is owned
by the core Registry, as `register_display` specifies. It is not a capability
to transfer.

| Transaction | Digest | Charge (SUI) |
| --- | --- | --- |
| Publish | `Fsp7aEP6bUpVjzuMaj7gnduSeKQ1EE2QZw3kNd5ytCBB` | 0.016212000 |
| PackageInfo, source metadata, name binding | `8f8dS64ooHMib5NFH3gG6k6E8kNR1ZpFao43ZB4B3Y5E` | 0.006105366 |
| Display registration | `GX6rFp9im517wc7TnCYkLbvkSnpb3Wt9Sc6Mijp1vzTP` | 0.009121343 |

### Example claims

Both claims are about the demo package itself and are owned by its derived
subject address,
`0x45d438e5a1329883246868f32fb7a58660387d653a0a19c45a24be69809fe959`. Their
report link is the [demo README at `51dd333`](https://github.com/MystenLabs/attestations/blob/51dd333579612fa6c517e58186a553d46efde0fe/demo/attestations-demo-auditor/README.md),
which is documentation, not an audit report. Neither records a report hash.

| Claim | Object | Description |
| --- | --- | --- |
| Live | `0x325033b2581243ee2ccfa3377ad2787d7b0a0caf47d09137ff2103b7e684c8ae` | `Live example; no security audit performed.` |
| Revoked | `0xbada7b8090e6cd3da9a11f0c7c9451898d0e09395d88612717ba1a575553b270` | `Revocation example; no security audit performed.` |

| Transaction | Digest | Charge (SUI) |
| --- | --- | --- |
| Issue live claim | `5eCv4PFLVWybubiT5mFDxF1TH8cLT2kUkcBogzxiunuk` | 0.003520133 |
| Issue revocation example | `DoX16aYH19M9HGjQWzdhC9zgRNJrHbgABfJreABDwPbX` | 0.003565733 |
| Revoke it | `67YJgdjQVpYbyQedxQfb8PfeNcfRt2pnU9Yx2WoGACSH` | 0.005147044 |

On-chain reads confirmed one claim with `revoked_at_ms: null` and one with a
revocation timestamp. Both render the demo Display without errors, and each
description carries the `DEMO ONLY - no security assurance.` prefix. Claims are
permanent; do not issue more examples to re-run the release check.

## Source and custody

Both packages use Sui toolchain **1.82.1**. Their Move sources are unchanged from
commit `5e613501cb22e3f07f778cff2ba5facebdf70fa8`. Each package's generated
`Move.lock` and `Published.toml` record its mainnet dependency graph and publication.
Existing testnet entries are preserved.

Both PackageInfo objects record this repository as their source, at revision
`51dd333579612fa6c517e58186a553d46efde0fe`, package version 1. Each MVR name is
permanently assigned to its mainnet package lineage and keeps its testnet
mapping.

| Holder | Holds |
| --- | --- |
| `0xa81a2328b7bbf70ab196d6aca400b5b0721dec7615bf272d95e0b0df04517e72` | core UpgradeCap, PackageInfo, AppCap |
| `0x893a5a7204dba4129790af587da6b99f8dabcfa64415c5c1d1295af9726a3512` (publishing wallet) | demo UpgradeCap, AuditAdminCap, PackageInfo, AppCap |

Both UpgradeCaps retain the default compatible policy. The shared Registry is a
protocol object, not a capability to transfer.

Verify the existing deployments without publishing again:

```sh
sui client --client.env mainnet verify-source packages/attestations
sui client --client.env mainnet verify-source demo/attestations-demo-auditor
```

## Remaining rollout work

Only the final multisig migration remains: move the capabilities listed under
custody to the multisig. The MVR name assignments stay with their package
lineages regardless of who holds the capabilities.
