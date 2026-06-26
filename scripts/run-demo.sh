#!/usr/bin/env bash
# Full single-command local demo:
#   - kill any prior `sui start --with-faucet` localnet
#   - start a fresh one
#   - test-publish all packages, upgrade audit_example, register Displays
#   - run the TS demo
#   - kill the localnet on exit (success or failure)
#
# Usage:
#   bash scripts/run-demo.sh                    # uses default `sui` on PATH
#   SUI=/path/to/sui bash scripts/run-demo.sh   # override sui binary
#   WITH_GRAPHQL=1 bash scripts/run-demo.sh     # also start GraphQL (:9125),
#                                               # needed by the MVR integration
#                                               # (requires a local Postgres).
#                                               # The TS demo itself uses gRPC
#                                               # and does not need it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUI="${SUI:-sui}"
LOCALNET_LOG="/tmp/sui-localnet-$$.log"

LOCAL_PID=""
cleanup() {
    if [[ -n "$LOCAL_PID" ]]; then
        echo
        echo "▶ stopping localnet (PID $LOCAL_PID)"
        kill "$LOCAL_PID" 2>/dev/null || true
        wait "$LOCAL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Kill any other lingering `sui start --with-faucet` from a prior run.
# Match against the binary path + the --with-faucet flag to avoid stomping
# on unrelated sui processes (sui-fork, indexers, etc.).
if pgrep -f 'sui start .*--with-faucet' >/dev/null; then
    echo "▶ killing prior localnet"
    pkill -f 'sui start .*--with-faucet' || true
    sleep 1
fi

GRAPHQL_FLAG=()
WAIT_PORTS="9000 9123"
if [[ -n "${WITH_GRAPHQL:-}" ]]; then
    GRAPHQL_FLAG=(--with-graphql)
    WAIT_PORTS="9000 9123 9125"
fi

echo "▶ starting localnet (log: $LOCALNET_LOG)"
# `${arr[@]+"${arr[@]}"}` expands to nothing when the array is empty, which
# avoids an "unbound variable" error from `set -u` on bash 3.2 (macOS).
"$SUI" start --force-regenesis --with-faucet ${GRAPHQL_FLAG[@]+"${GRAPHQL_FLAG[@]}"} > "$LOCALNET_LOG" 2>&1 &
LOCAL_PID=$!
# Wait for the JSON-RPC port (9000), the faucet port (9123), and — when
# requested — the GraphQL port (9125).
for port in $WAIT_PORTS; do
    for _ in {1..60}; do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
        sleep 0.5
    done
    if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
        echo "localnet port $port didn't come up; tail of log:"
        tail -20 "$LOCALNET_LOG"
        exit 1
    fi
done

echo "▶ switching sui client to local + faucet"
"$SUI" client switch --env local >/dev/null
"$SUI" client faucet >/dev/null
# Faucet credits are async; give them a beat to land before publish.
sleep 2

echo "▶ test-publish"
SETUP_OUT=$(SUI="$SUI" bash "$REPO_ROOT/scripts/test-publish.sh")
printf '%s\n' "$SETUP_OUT"

REGISTRY_ID=$(printf '%s\n' "$SETUP_OUT" \
    | awk '/^Registry shared object:/ {print $NF; exit}')
if [[ -z "$REGISTRY_ID" ]]; then
    echo "could not extract REGISTRY_ID from test-publish output" >&2
    exit 1
fi

echo
echo "▶ demo"
REGISTRY_ID="$REGISTRY_ID" pnpm --dir "$REPO_ROOT/ts" demo

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
