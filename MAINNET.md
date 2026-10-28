# Mainnet deployment

The core attestation registry and demonstration auditor are published on Sui
mainnet (`35834a8a`). Both passed source verification. The demo provides no
security assurance and must not be presented as a real security auditor.

## Core registry

Package path: [`packages/attestations`](packages/attestations).

| Object | ID |
| --- | --- |
| Package | `0xf918b2fc17085f4e48021be94ee43f9cc4437256acfd085f1e3d1a54d11f6e7b` |
| Shared Registry | `0x86875cdb65149c3a1c9653486c09ef7846a751823bb2a96d434fd01fbd4b052e` |
| UpgradeCap | `0xaad2df66d3540603774f4d37b02efd14615b0a6eba801dec2227f88fbba06b1b` |

Publish transaction: `8FNfq19cDWQy6sWEGDUWH5toyUzdKREkjesM97eH4yo7`.
Actual publication charge: **0.024184400 SUI**.

## Demonstration auditor

Package path: [`demo/attestations-demo-auditor`](demo/attestations-demo-auditor).
This package links to the mainnet core above, not the testnet registry.

| Object | ID |
| --- | --- |
| Package | `0x70b5189985e476f8f2e6f014ed9e2e6aeee71f4cafb07b768c3a7c7467e0e793` |
| AuditAdminCap | `0xbfe4d979dd69c6cda1928c31455be7804f057df0ff04789bc7d95d129dd5ed8c` |
| UpgradeCap | `0x87e04d36379c076abd1a3a1568ed662916e294ad2927c98aa34696dfb521e570` |

Publish transaction: `Fsp7aEP6bUpVjzuMaj7gnduSeKQ1EE2QZw3kNd5ytCBB`.
Actual publication charge: **0.016212000 SUI**.

## Source and custody

Both packages use Sui toolchain **1.82.1**. Their Move sources are unchanged from
commit `5e613501cb22e3f07f778cff2ba5facebdf70fa8`. Each package's generated
`Move.lock` and `Published.toml` record its mainnet dependency graph and publication.
Existing testnet entries are preserved.

The core UpgradeCap was transferred to the wallet that owns the
`@mysten/attestations` AppCap:

```text
0xa81a2328b7bbf70ab196d6aca400b5b0721dec7615bf272d95e0b0df04517e72
```

Transfer transaction: `2s5FvGdva73xuCxv1KKE8yVfuUGRSnfKUmos9wyHRtAd`.
Actual transfer charge: **0.000100163 SUI**. Ownership was read back and verified;
the capability's package, version, and policy are unchanged.

The publishing wallet retains the demo UpgradeCap and AuditAdminCap:

```text
0x893a5a7204dba4129790af587da6b99f8dabcfa64415c5c1d1295af9726a3512
```

Both UpgradeCaps retain the default compatible policy. Final multisig migration
remains pending. The shared Registry is a protocol object, not a capability to
transfer.

Verify the existing deployments without publishing again:

```sh
sui client --client.env mainnet verify-source packages/attestations
sui client --client.env mainnet verify-source demo/attestations-demo-auditor
```

## Remaining rollout work

Publication is complete; the following mainnet steps remain pending:

- Publish the release records to an immutable public source revision, then create
  PackageInfo for each deployment with that source link.
- Register the demo Display with its unconditional no-security-assurance warning.
- Assign `@mysten/attestations` and `@pkg/attestations-demo` to these deployments.
  Both mainnet bindings were empty at publication. Recheck before signing:
  mainnet assignment is permanent. Preserve their testnet mappings.
- Add the mainnet core and demo IDs to MVR's consumer configuration, issue two
  explicitly labeled examples about the demo package itself, and revoke one.
- Verify consumer reads and browser rendering before migrating custody.

The core name's AppCap and core UpgradeCap now have the same custody owner.
That signer can create PackageInfo, set its source metadata, permanently assign
the name, and transfer the new PackageInfo to its chosen owner in one PTB.
The source revision must be publicly available before preparing that transaction.
