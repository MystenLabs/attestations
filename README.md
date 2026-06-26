# Sui Attestation Registry PoC

A Move primitive for typed, on-chain attestations about arbitrary subjects
(packages, addresses, anything that has an `ID`), plus a TypeScript library
and CLI demo that exercises it.

The design is **off-chain-primary**: attestations are stored under a
deterministic, type-filterable on-chain layout that's cheap to enumerate from
indexers; cross-cutting behaviors like expiration are expressed as
Display-field **conventions** rather than additional Move types.

## Repo layout

```
packages/
  attestation_registry/       — the only deployable: Registry, Box, Attestation
examples/                     — reusable schema patterns for third-party attesters
  audit_example/              — sample schema: Audit { score: u8 } (+ AuditV2 upgrade)
demo/                         — fixtures that exist only to drive the local demo
  dependency_example/         — a subject; dependency of subject_example
  subject_example/            — the browsed subject (depends on dependency_example)
  untrusted_example/          — an attester deliberately NOT in the trusted set
ts/
  src/                        — client SDK: Box derivation, queries, conventions evaluator
  examples/audit.ts           — auditor-side PTB builders for the audit_example schema
  demo/                       — end-to-end CLI + dev tooling
CONVENTIONS.md                — Display-field conventions (expires_at, …)
FUTURE-EXTENSIONS.md          — design memos for surfaces deliberately deferred from v0
```

## Concepts in one paragraph

A `Registry` is a shared singleton, parent of one `Box` per attestation
subject. The Box's address is `derived_object::derive_address(registry, subject)`
— computable off-chain — so consumers can enumerate every attestation about
a subject via `getOwnedObjects(box_address, filter={StructType: …})`, with
server-side type filtering. Each `Attestation<T>` is owned by its Box via
transfer-to-object. Attestations are issued by `attestation_registry::attest`;
constructing the `T` value it takes is already restricted by Move to `T`'s
defining package, so the recorded attester is `T`'s package — bound to the
type at compile time, not denormalized into a field. Revocation moves an
attestation from its subject's active box to a separate revoked-sink address
and is gated by `Permit<T>`, which only `T`'s package can mint — so each
schema defines its own revocation authority (an admin cap, a per-attestation
bearer cap, or none at all). Time-based effectiveness (expiration) and other
cross-cutting concerns sit in the Display layer per the conventions in
`CONVENTIONS.md` — the registry itself stays minimal. ("Negative"
attestations — vulnerability disclosures that propagate from a dependency to
its dependents — are a planned fast-follow, not in this positive MVP.)

## Building and testing

Each Move package builds and tests independently. Run from the package's
directory:

```bash
cd packages/attestation_registry && sui move test
cd examples/audit_example        && sui move test
```

You'll need a `sui` CLI new enough to support the `#[error(code = …)]`
attribute and the `type_name::original_id` native helper — the testnet
release line at the time of writing (`v1.73.0`) is sufficient. Install or
update via `suiup install sui@testnet`.

## Running the TS demo

The demo creates Boxes for two real subjects (`dependency_example` and the
`subject_example` that depends on it), issues audits (an `Audit` on the
dependency; an `AuditV2` and a v1 `Audit` on the subject) plus two
attestations a trust consumer must filter out, then revokes the dependency's
audit and the subject's v1 `Audit` — showing each leave its active box (the
subject keeps its `AuditV2` as the live signal).

### One-command (recommended for iteration)

```bash
bash scripts/run-demo.sh
```

`scripts/run-demo.sh` owns the full lifecycle: kills any stale localnet,
starts a fresh `sui start --with-faucet`, waits for the JSON-RPC and faucet
ports, faucets gas, test-publishes all packages, registers Displays,
runs the demo, and **kills the localnet on exit** (success or failure).
Override the sui CLI binary with `SUI=/path/to/sui bash scripts/run-demo.sh`.

### Step-by-step (testnet or manual exploration)

The defaults target a local sui network (`sui start --with-faucet`); to point
at testnet or another remote network, pass `--rpc <url>` and `--pubfile <path>`.

Prerequisites:

1. Start a localnet in another shell:
   ```bash
   sui start --force-regenesis --with-faucet
   ```
   This serves gRPC + JSON-RPC on `127.0.0.1:9000` and a faucet on `:9123`.

2. Switch your sui CLI to it and faucet a bit of gas:
   ```bash
   sui client switch --env local      # use whichever env points at 127.0.0.1:9000
   sui client faucet
   ```

3. Test-publish all packages with one shared pubfile and register the
   Displays. The script does the whole sequence in one go and prints the
   `REGISTRY_ID=…` export line you'll need next:
   ```bash
   ./scripts/test-publish.sh
   ```
   That writes `Pub.localnet.toml` at the repo root (gitignored — ephemeral
   and per-user).

4. Export the printed Registry id:
   ```bash
   export REGISTRY_ID=0x…
   ```

Then:

```bash
cd ts
pnpm install
pnpm demo
```

The demo prints transaction digests and the rendered Display for each
attestation before and after the revoke.

Options:

- `--rpc <url>` — override the default localnet gRPC endpoint.
- `--pubfile <path>` — use a different pubfile (e.g. `Pub.testnet.toml`
  if you've published to testnet instead).
- `--subject <hex-id>` — re-use a specific subject ID. Default: a fresh
  random ID per run, so `create_box` doesn't collide on re-runs.

## Conventions evaluator

`ts/src/conventions.ts` implements `isEffective(attestation)`: an
attestation is effective iff its `expires_at` Display convention (if present)
is still in the future. Revocation is handled upstream by box membership — a
revoked attestation is read from the revoked sink, not the active box — so it
isn't part of this check. See `CONVENTIONS.md`.

## Branches

- `mdgeorge/draft` — TTO mainline (current).
- `mdgeorge/box-dof-reference` — DOF-storage snapshot from an earlier design
  iteration; preserved for comparison. See the commit log for the rationale
  for moving to TTO.

## Further reading

- `CONVENTIONS.md` — schema-level conventions for cross-cutting behaviors.
- `FUTURE-EXTENSIONS.md` — on-chain inspection APIs (borrow/put_back,
  data-by-copy) deferred from v0 with the design memos preserved.
