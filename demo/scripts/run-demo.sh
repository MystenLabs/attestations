#!/usr/bin/env bash
# Full single-command local demo:
#   - start a fresh localnet (fullnode + faucet + indexer Postgres + GraphQL),
#     managed by demo/scripts/localnets.py so its Postgres is torn down too
#   - test-publish all packages, upgrade auditor_a, register Displays
#   - run the shell demo (demo/scripts/demo.sh)
#   - stop the localnet *and its Postgres* on exit (success or failure)
#
# The localnet always runs the indexer + GraphQL (:9125): localnets.py owns the
# Postgres it points the indexer at, so unlike a bare `sui start --with-graphql`
# it leaves no orphaned Postgres behind. Requires python3 + local Postgres
# tools (initdb/pg_ctl/createdb) on PATH.
#
# Usage:
#   bash demo/scripts/run-demo.sh                  # default `sui` on PATH
#   SUI=/path/to/sui bash demo/scripts/run-demo.sh # override the sui binary

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUI="${SUI:-sui}"
LOCALNETS_PY="$(dirname "$0")/localnets.py"
LOCALNET_LOG="/tmp/sui-localnet-$$.log"
# localnets.py writes its postgres/ data dir and <name>.json pidfile into the
# cwd, so give it a private scratch dir (not the repo).
RUN_DIR="$(mktemp -d "/tmp/attest-demo-XXXXXX")"
READY_FILE="$RUN_DIR/ready"

PG_PORT=5433       # demo-private Postgres (avoids a system :5432)
FAUCET_PORT=9123
NETWORK="localnet,9000,9124,9125"   # NAME,FULLNODE,CONSISTENT,GRAPHQL

LOCAL_PID=""
cleanup() {
    if [[ -n "$LOCAL_PID" ]]; then
        echo
        echo "▶ stopping localnet + Postgres (PID $LOCAL_PID)"
        # SIGTERM triggers localnets.py's handler: terminate the localnet, then
        # pg_stop the Postgres it started.
        kill "$LOCAL_PID" 2>/dev/null || true
        wait "$LOCAL_PID" 2>/dev/null || true
    fi
    rm -rf "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "▶ starting localnet (log: $LOCALNET_LOG)"
# localnets.py invokes `sui` from PATH; prepend the chosen SUI's dir so a
# `SUI=/path/to/sui` override is honored. It writes postgres/ + <name>.json
# into its cwd, so run it from the private scratch dir.
( cd "$RUN_DIR" && PATH="$(dirname "$SUI"):$PATH" python3 "$REPO_ROOT/demo/scripts/localnets.py" \
    serve --ready "$READY_FILE" --pg-port "$PG_PORT" --faucet-port "$FAUCET_PORT" \
    --network "$NETWORK" ) > "$LOCALNET_LOG" 2>&1 &
LOCAL_PID=$!

echo "▶ waiting for localnet readiness"
if ! python3 "$LOCALNETS_PY" ready "$READY_FILE"; then
    echo "localnet failed to come up; tail of log:"
    tail -30 "$LOCALNET_LOG"
    exit 1
fi

echo "▶ switching sui client to local + faucet"
"$SUI" client switch --env local >/dev/null
"$SUI" client faucet >/dev/null
# Faucet credits are async; give them a beat to land before publish.
sleep 2

echo "▶ test-publish"
SETUP_OUT=$(SUI="$SUI" bash "$REPO_ROOT/demo/scripts/test-publish.sh")
printf '%s\n' "$SETUP_OUT"

REGISTRY_ID=$(printf '%s\n' "$SETUP_OUT" \
    | awk '/^Registry shared object:/ {print $NF; exit}')
if [[ -z "$REGISTRY_ID" ]]; then
    echo "could not extract REGISTRY_ID from test-publish output" >&2
    exit 1
fi

echo
echo "▶ demo"
REGISTRY_ID="$REGISTRY_ID" bash "$REPO_ROOT/demo/scripts/demo.sh"

echo
echo "▶ done"

# For the MVR integration the localnet must outlive this script so the demo
# server (resolution) and the frontend (chain reads) can use it. KEEP_ALIVE
# blocks here, holding the localnet up until interrupted (Ctrl-C), at which
# point the EXIT trap tears it down.
if [[ -n "${KEEP_ALIVE:-}" ]]; then
    echo
    echo "▶ localnet staying up (KEEP_ALIVE). Registry id: $REGISTRY_ID"
    echo "  demo-ids.json written to $REPO_ROOT/demo-ids.json"
    echo "  Press Ctrl-C to stop."
    wait "$LOCAL_PID"
fi
