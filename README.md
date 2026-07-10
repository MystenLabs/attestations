# Sui Attestation Registry PoC

A Move primitive for typed, on-chain attestations (e.g. audits) about arbitrary
subjects (packages, addresses, anything that has an `ID`), plus a shell CLI demo
that exercises it.

The design is **off-chain-primary**: attestations are stored under a
deterministic, type-filterable on-chain layout that's cheap to enumerate from
indexers; cross-cutting behaviors like expiration are expressed as
Display-field **conventions** rather than additional Move types.

## Repo layout

```
packages/
  attestations/       — the only deployable: Registry, Box, Attestation
examples/                     — reusable schema patterns for third-party attesters
  auditor/                    — reference auditor schema (`Audit` + `AuditAdminCap`)
demo/                         — fixtures that exist only to drive the local demo (see demo/README.md)
  auditor_a/                  — copy of examples/auditor + an AuditV2 upgrade; TRUSTED in the demo
  auditor_b/                  — a second copy; NOT trusted (the identity-based-trust demo)
  dependency_example/         — a subject; dependency of subject_example
  subject_example/            — the browsed subject (depends on dependency_example)
  scripts/                    — demo orchestration: run-demo.sh, test-publish.sh, demo.sh
scripts/                      — reusable CLI ops: create-box, attest-audit, revoke-audit
CONVENTIONS.md                — Display-field conventions (expires_at, …)
FUTURE-EXTENSIONS.md          — design memos for surfaces deliberately deferred from v0
```

## Concepts

```
Registry (shared singleton)
  └── Box (per subject; active + revoked) ──owns──▶ Attestation<T> (TTO)
```

A `Registry` is a shared singleton, parent of two `Box`es per subject — an
*active* box and a *revoked* box. A box's address is
`derived_object::derive_address(registry, BoxKey { subject, revoked })` —
computable off-chain — so consumers enumerate every un-revoked attestation about
a subject via `getOwnedObjects(active_box, filter={StructType: …})`, with
server-side type filtering. Each `Attestation<T>` is owned by its Box via
transfer-to-object.

The key design feature is that **the schema package has complete control over
its attestations.** `attest`, `revoke`, and `register_display` are all gated by
`Permit<T>`, which Move lets only `T`'s defining package mint — so only that
package can issue, revoke, or set the Display for `Attestation<T>`. The
recorded attester is therefore `T`'s package — bound to the type at compile
time, not denormalized into a field — and each schema defines its own revocation
authority (an admin cap, a per-attestation bearer cap, or none at all).
Revocation moves an attestation from the subject's active box to its revoked
box. Time-based effectiveness (expiration) and other cross-cutting concerns sit
in the Display layer per `CONVENTIONS.md` — the registry itself stays minimal.
("Negative" attestations — vulnerability disclosures that propagate from a
dependency to its dependents — are a planned fast-follow, not in this positive
MVP.)

## Building and testing

```bash
bash scripts/check.sh                          # every package
bash scripts/check.sh packages/attestations    # just the ones named
```

`check.sh` attempts every package even if one fails, and exits nonzero if any
did. Each Move package also builds and tests independently, but they pin
env-specific dependencies, so a direct `sui move test` needs a build env:

```bash
cd packages/attestations && sui move test --build-env testnet
```

## Running the demo

The demo creates Boxes for two real subjects (`dependency_example` and the
`subject_example` that depends on it), issues audits (an `Audit` on the
dependency; an `AuditV2` and a v1 `Audit` on the subject) plus two
attestations a trust consumer must filter out, then revokes the dependency's
audit and the subject's v1 `Audit` — showing each leave its active box (the
subject keeps its `AuditV2` as the live signal).

### One-command (recommended for iteration)

```bash
bash demo/scripts/demo-up.sh                            # chain only
MVR_DIR=/path/to/mvr bash demo/scripts/demo-up.sh       # + demo_server :8000, app :3000
bash demo/scripts/demo-down.sh                          # idempotent; always safe
```

`demo-up.sh` brings up the stack and tears it all down on Ctrl-C. Underneath it,
`demo/scripts/run-demo.sh` owns the chain lifecycle: it starts a fresh localnet,
waits for readiness, faucets gas, test-publishes every package, registers
Displays, runs the demo, and stops the localnet **and its Postgres** on exit.
Override the sui CLI binary with `SUI=/path/to/sui`.

`SIGKILL` (`kill -9`, `pkill -9`, a reaped background shell) skips every shell
trap, so nothing gets to clean up and the demo's Postgres is left running. Use
Ctrl-C, and if a stack does get killed that way run `demo-down.sh` — it reclaims
the ports and removes the scratch dirs without relying on any trap having run.

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
   ./demo/scripts/test-publish.sh
   ```
   That writes `Pub.localnet.toml` at the repo root (gitignored — ephemeral
   and per-user).

4. Export the printed Registry id:
   ```bash
   export REGISTRY_ID=0x…
   ```

Then run the demo (it reads `Pub.localnet.toml` and `REGISTRY_ID`):

```bash
bash demo/scripts/demo.sh
```

`demo/scripts/demo.sh` composes the `scripts/` CLI ops (create-box, attest-audit,
revoke-audit): it creates the boxes, issues the audits, revokes two of them, and
writes `demo-ids.json` for the MVR seeder, printing each step's object ids.

Options:

- `--rpc <url>` — override the default localnet gRPC endpoint.
- `--pubfile <path>` — use a different pubfile (e.g. `Pub.testnet.toml`
  if you've published to testnet instead).
- `--subject <hex-id>` — re-use a specific subject ID. Default: a fresh
  random ID per run, so `create_box` doesn't collide on re-runs.

## Effectiveness

Off-chain consumers decide whether an attestation is *effective*: it must be
unexpired per the `expires_at` Display convention (if present). Revocation is
handled upstream by box membership — a revoked attestation lives in the revoked
box, not the active one — so it isn't part of that check. See `CONVENTIONS.md`
for the conventions and their evaluation rules.

## Further reading

- `CONVENTIONS.md` — schema-level conventions for cross-cutting behaviors.
- `FUTURE-EXTENSIONS.md` — the deferred on-chain inspection API (borrow/put_back
  hot potato) with the design memo preserved.
