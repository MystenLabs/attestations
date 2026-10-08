#!/usr/bin/env bash
# End-to-end test on a fresh local network:
#
#   1. start `sui start --with-faucet --with-graphql --force-regenesis`
#   2. publish every package and run the demo scenario
#      (demo/scripts/test-publish.sh, then demo/scripts/demo.sh)
#   3. follow examples/auditor's onboarding guide as a new auditor would
#      (e2e/walkthrough.sh)
#   4. check the attestation state that then lives on the localnet against its
#      insta snapshot (`cargo test` in e2e/, which reads it through GraphQL, the
#      way a consumer would)
#
# Everything it creates (sui client config, the localnet's databases, pubfile,
# demo-ids.json, logs) lives in one work dir, removed on exit.
#
# Usage:
#   bash e2e/run.sh
#   cargo insta review --manifest-path e2e/Cargo.toml   # if it left a changed snapshot
#
#   PORT_OFFSET=10000 bash e2e/run.sh        # run beside a localnet on the default ports
#   E2E_WORK_DIR=/some/dir bash e2e/run.sh   # use, and keep, this (empty) work dir
#   SUI=/path/to/sui bash e2e/run.sh         # override the sui binary
#
# Needs sui, cargo, jq, curl, python3 (3.11+), and the Postgres server binaries
# (initdb, postgres, pg_ctl) on PATH: the localnet's indexer runs a temporary
# database of its own. Stop it with Ctrl-C, never `kill -9`: SIGKILL skips the
# cleanup below and leaves that database running.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUI="${SUI:-sui}"
export SUI # test-publish.sh and walkthrough.sh read it

PORT_OFFSET="${PORT_OFFSET:-0}"
RPC_PORT=$((9000 + PORT_OFFSET))
FAUCET_PORT=$((9123 + PORT_OFFSET))
CONSISTENT_PORT=$((9124 + PORT_OFFSET))
GRAPHQL_PORT=$((9125 + PORT_OFFSET))
RPC_URL="http://127.0.0.1:$RPC_PORT"
GRAPHQL_URL="http://127.0.0.1:$GRAPHQL_PORT/graphql"
READY_TIMEOUT=180

E2E_MANIFEST="$REPO_ROOT/e2e/Cargo.toml"
# The walkthrough's subject: made up, so it stays apart from the demo's.
WALKTHROUGH_SUBJECT=0x0000000000000000000000000000000000000000000000000000000000007e57

if [[ -n "${E2E_WORK_DIR:-}" ]]; then
    mkdir -p "$E2E_WORK_DIR"
    if [[ -n "$(ls -A "$E2E_WORK_DIR")" ]]; then
        echo "✘ E2E_WORK_DIR=$E2E_WORK_DIR is not empty" >&2
        exit 1
    fi
    WORK="$(cd "$E2E_WORK_DIR" && pwd)"
    KEEP_WORK=1
else
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/attest-e2e-XXXXXX")"
    KEEP_WORK=""
fi
PUBFILE="$WORK/Pub.localnet.toml"
LOCALNET_LOG="$WORK/localnet.log"

SUI_PID=""
# Bound to EXIT only; INT and TERM just exit, which runs it once.
cleanup() {
    if [[ -n "$SUI_PID" ]] && kill -0 "$SUI_PID" 2>/dev/null; then
        echo "▶ stopping the localnet"
        # SIGINT, not SIGTERM: on SIGINT `sui start` also stops its indexer's
        # temporary Postgres, on SIGTERM it leaves it running.
        kill -INT "$SUI_PID" 2>/dev/null || true
        for _ in $(seq 1 60); do
            kill -0 "$SUI_PID" 2>/dev/null || break
            sleep 0.5
        done
    fi
    # In case it didn't: stop any Postgres still running out of the work dir.
    while IFS= read -r pidfile; do
        pg_ctl stop -m fast -w -t 10 -D "$(dirname "$pidfile")" >/dev/null 2>&1 || true
    done < <(find "$WORK" -name postmaster.pid 2>/dev/null)

    if [[ -n "$KEEP_WORK" ]]; then
        echo "▶ work dir kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Build the snapshot test first, so a compile error fails before the localnet
# starts, and the localnet isn't left waiting on a build.
echo "▶ building the snapshot test (e2e/)"
cargo test --manifest-path "$E2E_MANIFEST" --locked --test attestation_state --no-run --quiet

# --- 1. Localnet ---

echo "▶ starting the localnet (log: $LOCALNET_LOG)"
mkdir -p "$WORK/sui-tmp"
# `exec`, so that $! is `sui start` itself rather than a subshell. Its node and
# indexer databases go under $TMPDIR, which we point into the work dir.
(
    cd "$WORK" && TMPDIR="$WORK/sui-tmp" exec "$SUI" start --force-regenesis \
        --fullnode-rpc-port "$RPC_PORT" \
        --with-faucet="127.0.0.1:$FAUCET_PORT" \
        --with-consistent-store="127.0.0.1:$CONSISTENT_PORT" \
        --with-graphql="127.0.0.1:$GRAPHQL_PORT"
) >"$LOCALNET_LOG" 2>&1 &
SUI_PID=$!

# GraphQL is the last service up, so it stands for the rest.
graphql_ready() {
    local body
    body=$(curl -sf -m 2 "$GRAPHQL_URL" -H 'content-type: application/json' \
        -d '{"query":"{ chainIdentifier }"}') || return 1
    [[ "$body" == *'"chainIdentifier":"'* ]]
}
deadline=$((SECONDS + READY_TIMEOUT))
until graphql_ready; do
    if ! kill -0 "$SUI_PID" 2>/dev/null; then
        echo "✘ sui start exited; the end of its log:"
        tail -30 "$LOCALNET_LOG"
        exit 1
    fi
    if ((SECONDS >= deadline)); then
        echo "✘ the localnet wasn't ready after ${READY_TIMEOUT}s; the end of its log:"
        tail -30 "$LOCALNET_LOG"
        exit 1
    fi
    sleep 1
done
echo "  ready"

echo "▶ sui client config for the localnet, with gas"
export SUI_CONFIG_DIR="$WORK/client"
mkdir -p "$SUI_CONFIG_DIR"
# --yes creates the config on first use. Its built-in `local` env assumes the
# default port, so use our own env.
"$SUI" client --yes new-env --alias e2e --rpc "$RPC_URL" >"$WORK/client.log" 2>&1
"$SUI" client switch --env e2e >>"$WORK/client.log" 2>&1
SENDER=$("$SUI" client active-address)

# The faucet can come up a moment after GraphQL, and its coins land
# asynchronously.
for attempt in $(seq 1 30); do
    if "$SUI" client faucet --url "http://127.0.0.1:$FAUCET_PORT/v2/gas" >>"$WORK/client.log" 2>&1; then
        break
    fi
    if ((attempt == 30)); then
        echo "✘ the faucet kept failing:"
        tail -20 "$WORK/client.log"
        exit 1
    fi
    sleep 1
done
gas_coins() {
    "$SUI" client gas --json 2>/dev/null | jq '.gasCoins | length'
}
deadline=$((SECONDS + 60))
until [[ "$(gas_coins)" -gt 0 ]]; do
    if ((SECONDS >= deadline)); then
        echo "✘ no gas for $SENDER 60s after the faucet request"
        exit 1
    fi
    sleep 1
done
echo "  $SENDER"

# --- 2. Demo ---

echo
echo "▶ publish every package (demo/scripts/test-publish.sh)"
bash "$REPO_ROOT/demo/scripts/test-publish.sh" "$PUBFILE" | tee "$WORK/publish.log"
REGISTRY_ID=$(awk '/^Registry shared object:/ {print $NF; exit}' "$WORK/publish.log")
if [[ -z "$REGISTRY_ID" ]]; then
    echo "✘ test-publish.sh didn't print the Registry id"
    exit 1
fi

echo
echo "▶ the demo scenario (demo/scripts/demo.sh)"
GRAPHQL="$GRAPHQL_URL" PUBFILE="$PUBFILE" REGISTRY_ID="$REGISTRY_ID" DEMO_IDS="$WORK/demo-ids.json" \
    bash "$REPO_ROOT/demo/scripts/demo.sh" | tee "$WORK/demo.log"

# --- 3. Template walkthrough ---

echo
echo "▶ the examples/auditor onboarding guide (e2e/walkthrough.sh)"
PUBFILE="$PUBFILE" REGISTRY_ID="$REGISTRY_ID" SUBJECT="$WALKTHROUGH_SUBJECT" \
    bash "$REPO_ROOT/e2e/walkthrough.sh" "$WORK" | tee "$WORK/walkthrough.log"

# --- 4. Snapshot ---

echo
echo "▶ check the on-chain state against its snapshot (e2e/tests/attestation_state.rs)"
# GraphQL's indexer trails the chain, so the test first waits until it has the
# run's last transaction. Every transaction comes from the one client address
# and writes its gas coin, so the sender's most recently written object was
# last written by that transaction. (`sui client objects --json` prints the
# objects as the fullnode returns them.)
LAST_DIGEST=$("$SUI" client objects --json |
    jq -r 'max_by(.data.Move.version) | .previous_transaction // empty')
if [[ -z "$LAST_DIGEST" ]]; then
    echo "✘ couldn't find the run's last transaction among $SENDER's objects"
    exit 1
fi
if ! E2E_GRAPHQL_URL="$GRAPHQL_URL" E2E_PUBFILE="$PUBFILE" \
    E2E_REGISTRY_ID="$REGISTRY_ID" E2E_LAST_DIGEST="$LAST_DIGEST" \
    E2E_WALKTHROUGH_SUBJECT="$WALKTHROUGH_SUBJECT" \
    cargo test --manifest-path "$E2E_MANIFEST" --locked --test attestation_state --quiet; then
    echo
    echo "✘ the on-chain state differs from e2e/tests/snapshots/attestation_state.snap."
    echo "  If the change is intended, accept it from a local run (CI doesn't keep it):"
    echo "    cargo insta review --manifest-path e2e/Cargo.toml"
    exit 1
fi
echo "✔ the on-chain state matches its snapshot"
