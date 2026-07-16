#!/usr/bin/env bash
# One-command local demo stack.
#
#   chain    : localnet + publish + the attestation demo  (run-demo.sh, KEEP_ALIVE)
#   frontend : demo_server (:8000) + the mvr app (:3000), when MVR_DIR is set
#
# Ctrl-C or SIGTERM tears the whole stack down, including the localnet's
# Postgres. If this script is SIGKILLed the traps are skipped — run
# `demo/scripts/demo-down.sh` afterwards to sweep the leftovers.
#
# Usage:
#   bash demo/scripts/demo-up.sh                                    # chain only
#   MVR_DIR=~/projects/attestations-mvr-grpc bash demo/scripts/demo-up.sh
#
#   SUI=/path/to/sui  ...                                           # override the binary

set -euo pipefail

# Job control: each background job gets its own process group, so killing -PID
# takes the whole tree with it. Without this, `kill` hits `cargo`/`pnpm` and
# orphans the demo_server / next child still holding the port.
set -m

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUI="${SUI:-sui}"
MVR_DIR="${MVR_DIR:-}"
LOG_DIR="$(mktemp -d "/tmp/attest-demo-logs-XXXXXX")"

pids=()

# Bind cleanup to EXIT only. Bash runs an EXIT trap on SIGTERM, so binding it to
# `EXIT INT TERM` as well would run it two or three times; instead let INT/TERM
# turn into an ordinary exit, which fires EXIT exactly once.
cleanup() {
    echo
    echo "▶ stopping demo stack"
    for pid in ${pids[@]+"${pids[@]}"}; do
        kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in ${pids[@]+"${pids[@]}"}; do
        wait "$pid" 2>/dev/null || true
    done
    bash "$REPO_ROOT/demo/scripts/demo-down.sh" || true
    rm -rf "$LOG_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Block until $1 (a log file) contains $2, failing fast if the job died first.
wait_for_log() {
    local log="$1" needle="$2" pid="$3"
    until grep -q "$needle" "$log" 2>/dev/null; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "✘ died before it was ready; last 30 lines of $log:" >&2
            tail -30 "$log" >&2
            exit 1
        fi
        sleep 1
    done
}

# Block until something is listening on 127.0.0.1:$1 (timeout $2 seconds).
wait_for_port() {
    local port="$1" deadline=$((SECONDS + $2))
    while (( SECONDS < deadline )); do
        # The subshell's status is the redirection's: 0 iff the connect succeeded.
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo "✘ nothing listening on :$port after $2s" >&2
    return 1
}

echo "▶ chain: localnet + publish + demo   (log: $LOG_DIR/chain.log)"
KEEP_ALIVE=1 SUI="$SUI" bash "$REPO_ROOT/demo/scripts/run-demo.sh" \
    >"$LOG_DIR/chain.log" 2>&1 &
pids+=("$!")
wait_for_log "$LOG_DIR/chain.log" "localnet staying up" "${pids[0]}"
echo "  ✔ localnet :9000 (gRPC) · GraphQL :9125 · demo-ids.json written"

if [[ -n "$MVR_DIR" ]]; then
    if [[ ! -f "$MVR_DIR/scripts/write-demo-env.sh" ]]; then
        echo "✘ MVR_DIR=$MVR_DIR has no scripts/write-demo-env.sh" >&2
        exit 1
    fi

    echo "▶ frontend: app/.env from demo-ids.json"
    bash "$MVR_DIR/scripts/write-demo-env.sh" "$REPO_ROOT/demo-ids.json"

    echo "▶ frontend: demo_server :8000   (log: $LOG_DIR/demo-server.log)"
    (cd "$MVR_DIR" && cargo run -q -p mvr-api --example demo_server -- \
        --demo-ids "$REPO_ROOT/demo-ids.json" --port 8000) \
        >"$LOG_DIR/demo-server.log" 2>&1 &
    pids+=("$!")
    wait_for_port 8000 180

    echo "▶ frontend: mvr app :3000       (log: $LOG_DIR/app.log)"
    (cd "$MVR_DIR" && pnpm --dir app dev) >"$LOG_DIR/app.log" 2>&1 &
    pids+=("$!")
    wait_for_port 3000 120

    echo
    echo "  ✔ http://localhost:3000/package/@demo/subject"
    echo "    http://localhost:3000/package/@auditor-a/audit   (trusted; Issued tab in nav)"
    echo "    http://localhost:3000/package/@auditor-b/audit   (untrusted; Issued by URL only)"
fi

echo
echo "▶ stack is up. Press Ctrl-C to tear it down."
wait
