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
  attestations/       — the only deployable: Registry, Attestation
examples/             — reusable schema patterns for third-party attesters
  auditor/            — reference auditor schema (`Audit` + `AuditAdminCap`)
demo/                 — fixtures that exist only to drive the local demo (see demo/README.md)
  auditor_a/          — copy of examples/auditor + an AuditV2 upgrade; TRUSTED in the demo
  auditor_b/          — a second copy; NOT trusted (the identity-based-trust demo)
  auditor_c/          — a third copy; a second TRUSTED attester
  dependency_example/ — a subject; dependency of subject_example
  subject_example/    — the browsed subject (depends on dependency_example)
  scripts/            — demo orchestration: run-demo.sh, test-publish.sh, demo.sh
scripts/              — reusable CLI ops: attest-audit, revoke-audit
CONVENTIONS.md        — Display-field conventions (expires_at, …)
FUTURE-EXTENSIONS.md  — design memos for surfaces deliberately deferred from v0
```

## Concepts

```
Registry (shared singleton; holds the anchor UIDs that `revoke` claims)
  └── derive_address(registry, subject) ──owns──▶ Attestation<T> (TTO), live or revoked
```

A `Registry` is a shared singleton. Each subject's attestations live at one
address, `derived_object::derive_address(registry, subject)`, which consumers
compute off-chain from the registry and subject ids. They list a subject's
attestations via `getOwnedObjects(address, filter={StructType: …})`, with
server-side type filtering. Each attestation records its own status: it is
revoked iff its `revoked_at_ms` field is set.

`revoke` needs a `&mut UID` at the subject's address to `transfer::receive`
from. The first `revoke` for a subject claims that UID and keeps it in the
Registry's `anchors` table, so no object exists at the address, and no setup
transaction comes before the first revoke.

The key design feature is that **the schema package has complete control over
its attestations.** `attest`, `revoke`, and `register_display` are all gated by
`Permit<T>`, which Move lets only `T`'s defining package mint — so only that
package can issue, revoke, or set the Display for `Attestation<T>`. The
recorded attester is therefore `T`'s package — bound to the type at compile
time, not denormalized into a field — and each schema defines its own revocation
authority (an admin cap, a per-attestation bearer cap, or none at all).
Revocation sets an attestation's `revoked_at_ms` and leaves it at its subject's
address. Time-based effectiveness (expiration) and other cross-cutting concerns
sit in the Display layer per `CONVENTIONS.md` — the registry itself stays minimal.
("Negative" attestations — vulnerability disclosures that propagate from a
dependency to its dependents — are a planned fast-follow, not in this positive
MVP.)

## Auditor onboarding

Start with the [auditor template](examples/auditor/README.md) to issue your own
company's audit attestations. The installable
[auditor-onboarding skill](skills/auditor-onboarding/SKILL.md) guides an agent
through testnet setup, publishing, capability custody, SuiNS/MVR registration,
issuance, revocation, and browser verification before a separate mainnet rollout.

Install it with the [skills CLI](https://github.com/vercel-labs/skills):

```sh
npx skills add MystenLabs/attestations --skill auditor-onboarding
```

From a local checkout, use `npx skills add ./skills/auditor-onboarding` instead.
Choose your agent when prompted. Alternatively, copy the entire
`skills/auditor-onboarding` directory into your agent's supported skills directory;
keep its `references/` folder beside `SKILL.md`. No other skills are required.
The workflow requires user approval before transactions and does not automatically
grant inclusion in Move Registry's trusted-attester list.

## Building and testing

```bash
bash scripts/check.sh                          # lint, build, and test every package
bash scripts/check.sh packages/attestations    # just the ones named
bash scripts/check-format.sh                   # Move formatting; --write to fix
bash scripts/check-template.sh                 # examples/auditor against this checkout
bash e2e/run.sh                                # end to end on a fresh localnet
```

`check.sh` attempts every package even if one fails, and exits nonzero if any
did. Each Move package also builds and tests independently, but they pin
env-specific dependencies, so a direct `sui move test` needs a build env:

```bash
cd packages/attestations && sui move test --build-env testnet
```

`e2e/run.sh` starts a localnet, publishes every package, runs the demo and the
`examples/auditor` onboarding guide, and checks the resulting on-chain state
against an [insta](https://insta.rs) snapshot,
`e2e/tests/snapshots/attestation_state.snap`. When a change to that state is
intended, the run leaves the new snapshot for
`cargo insta review --manifest-path e2e/Cargo.toml`. CI runs all of these on
every pull request.

## Running the demo

The demo attests about two real subjects (`dependency_example` and the
`subject_example` that depends on it): an `Audit` on the dependency, an
`AuditV2` and a v1 `Audit` on the subject, and two attestations a trust consumer
must filter out. It then revokes the subject's v1 `Audit`, which stays at the
subject's address with `revoked_at_ms` set (the subject keeps its `AuditV2` as
the live signal).

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

The defaults target a local sui network (`sui start --with-faucet
--with-graphql`); to point at testnet or another remote network, switch your
sui client to it and set `GRAPHQL` and `PUBFILE` (see below).

Prerequisites:

1. Start a localnet in another shell:
   ```bash
   sui start --force-regenesis --with-faucet --with-graphql
   ```
   This serves gRPC on `127.0.0.1:9000`, a faucet on `:9123`, and GraphQL on
   `:9125`, which `demo.sh` reads owned objects from. GraphQL's indexer runs a
   temporary Postgres, so the Postgres server binaries must be on `PATH`.

2. Switch your sui CLI to it and faucet a bit of gas:
   ```bash
   sui client switch --env local      # use whichever env points at 127.0.0.1:9000
   sui client faucet
   ```

3. Test-publish all packages with one shared pubfile and register the
   Displays. The script does the whole sequence in one go and prints the
   `REGISTRY_ID=…` value you'll need next:
   ```bash
   ./demo/scripts/test-publish.sh
   ```
   That writes `Pub.localnet.toml` at the repo root (gitignored — ephemeral
   and per-user).

4. Export the printed id of the shared `Registry`:
   ```bash
   export REGISTRY_ID=0x…
   ```

Then run the demo (it reads `Pub.localnet.toml` and `REGISTRY_ID`):

```bash
bash demo/scripts/demo.sh
```

`demo/scripts/demo.sh` composes the `scripts/` CLI ops (attest-audit,
revoke-audit): it issues the audits, revokes one of them, and writes
`demo-ids.json` for the MVR seeder, printing each step's object ids.

Options, as environment variables:

- `GRAPHQL=<url>` — the GraphQL endpoint `demo.sh` reads owned objects from.
  Default: the localnet's, `http://127.0.0.1:9125/graphql`.
- `PUBFILE=<path>` — use a different pubfile (e.g. `Pub.testnet.toml`
  if you've published to testnet instead).
- `DEMO_IDS=<path>` — where to write `demo-ids.json`. Default: the repo root.

## Effectiveness

Off-chain consumers decide whether an attestation is *effective*: its
`revoked_at_ms` must be none, and it must be unexpired per the `expires_at`
Display convention (if present). A revoked attestation stays at its subject's
address, so a consumer that lists the address must check `revoked_at_ms`. See
`CONVENTIONS.md` for the conventions and their evaluation rules.

## Further reading

- `CONVENTIONS.md` — schema-level conventions for cross-cutting behaviors.
- `FUTURE-EXTENSIONS.md` — the deferred on-chain inspection API (borrow/put_back
  hot potato) with the design memo preserved.
