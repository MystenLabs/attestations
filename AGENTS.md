# AGENTS.md

Working notes for coding agents in this repo. `README.md` is the front door for
humans; this file is the short version plus the traps that aren't obvious from
reading the code.

## What this is

A typed attestation registry for Sui. `Attestation<T>` wraps an arbitrary schema
`T`, and only `T`'s defining module can mint the `Permit<T>` that authorizes
`attest`, `revoke`, and `register_display`. Each subject has one claimed `Box`
(the active box) plus a derived revoked address; an attestation's status is
simply which of the two owns it. Rationale is in `DESIGN.md`; Display field
conventions in `CONVENTIONS.md`.

## Layout

| Path | What it is |
| --- | --- |
| `packages/attestations` | the core registry package — the only thing that ships |
| `examples/auditor` | reference schema plus the new-attester onboarding guide (`README.md`); built and tested standalone, **not** part of the demo |
| `demo/*` | independently published copies used by the demo, each with its own package identity |
| `scripts/`, `demo/scripts/` | publish helpers, the local demo stack, and the `check-*.sh` checks |
| `.github/` | CI, which runs every check below on each PR and push to `main` |

`examples/` versus `demo/` is a real distinction, not duplication. The demo needs
several *distinct on-chain packages* — two trusted auditors and one untrusted —
to show trust filtering, while `examples/auditor` has to stay a clean template.

## Build and test

```sh
bash scripts/check.sh                          # lint, build, and test every Move package
bash scripts/check.sh packages/attestations    # just the ones named
bash scripts/check-format.sh                   # Move formatting; --write to fix
bash scripts/check-template.sh                 # examples/auditor against this checkout
```

CI (`.github/workflows/ci.yml`) runs all of these, with the latest `sui` from
`suiup`.

`sui move test` builds the package and runs its tests, so that single command
covers packages with and without tests. `check.sh` runs it with `--lint
--warnings-are-errors`, so a lint warning fails the package. It attempts every
package even if one fails, and exits nonzero if any did.

`check-format.sh` needs prettier-move (`npm i -g prettier
@mysten/prettier-plugin-move`); its settings are in `.prettierrc`.

`examples/auditor` depends on the registry by its MVR name, which resolves to the
*published* package, so `check.sh` alone tests it against that release.
`check-template.sh` also builds a copy pointed at this checkout's registry, and
checks that `demo/auditor_*` are still copies of the template.

These packages pin env-specific dependencies, so a bare `sui move test` fails
with "could not determine the correct dependencies"; it needs `--build-env
testnet`. `check.sh` passes that for you (override with `BUILD_ENV=mainnet`).

Abort codes use `#[error(code = N)]` and the tests refer to them **by name**, so
renumbering is transparent. Don't hardcode code numbers in tests.

Don't hand-edit `Move.lock`. Bump framework deps with `suiup install` followed by
`sui move update-deps`.

## The demo

```sh
bash demo/scripts/demo-up.sh                          # chain only
MVR_DIR=/path/to/mvr bash demo/scripts/demo-up.sh     # + demo_server :8000, app :3000
bash demo/scripts/demo-down.sh                        # idempotent; always safe
```

**Never `kill -9` or `pkill -9` the demo.** `SIGKILL` skips every shell trap, so
`localnets.py` never reaches its `pg_stop`: the demo Postgres keeps running and
its scratch dir survives under `/tmp/attest-demo-*`. These accumulate silently
and are easy to miss until the disk fills. `SIGTERM` and Ctrl-C *are* handled
correctly. If a stack does get `SIGKILL`ed — a reaped background shell will do
it — run `demo-down.sh`, which sweeps orphaned Postgres clusters and scratch
dirs without relying on any trap having run.

The frontend lives in a different repo (`MystenLabs/mvr`). The chain side writes
`demo-ids.json`, which that repo's `scripts/write-demo-env.sh` consumes.

## Traps

- **`sui ... --json` writes JSON to stdout and build logs to stderr.** Redirect
  the two streams separately and parse stdout with `jq`, rather than trying to
  strip log lines out of a merged stream.
- **Never pipe a compiler or typechecker and then trust `$?`.** `tsc` writes its
  errors to *stdout*, and `cmd | tail -3 && echo OK` cheerfully reports success
  for a failed build. Check the exit status of the command itself.
- Bash runs an `EXIT` trap on `SIGTERM`, but not on `SIGKILL`. Binding a cleanup
  function to `EXIT INT TERM` runs it more than once; bind it to `EXIT` alone and
  let `INT`/`TERM` handlers just `exit`.
- In bash, `( cmd ) &` sets `$!` to the **subshell's** pid, not `cmd`'s, so
  `kill "$!"` kills the subshell and orphans `cmd` — its signal handlers never
  run. Put `exec` before the final command so `$!` is the command itself. (zsh
  optimises the subshell away, so a quick check in an interactive zsh will
  wrongly suggest the plain form is fine.)
- Background jobs need `set -m` for `kill -TERM -$pid` to take the whole process
  group. Otherwise `kill` hits `cargo` or `pnpm` and orphans the child that is
  actually holding the port.
- **Reformatting a published module changes its bytecode.** `#[error]` abort
  codes encode the source line of the abort, so any line shift changes them, and
  a rebuild no longer byte-matches the deployed package.

## Further reading

`README.md` · `DESIGN.md` · `CONVENTIONS.md` · `FUTURE-EXTENSIONS.md` ·
`packages/attestations/README.md` · `examples/auditor/README.md`
