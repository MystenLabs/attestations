#!/usr/bin/env bash
# Tear down leftover demo localnet state, however the demo died.
#
# run-demo.sh cleans up after itself on a normal exit and on SIGTERM, but
# SIGKILL (`kill -9`, `pkill -9`, a reaped background shell) skips every shell
# trap: localnets.py never reaches its `pg_stop`, so the demo Postgres keeps
# running and its scratch dir survives with the `postgres/data` cluster inside.
#
# This sweeper relies on no trap having run. It is idempotent — safe to run when
# nothing is up, and safe to run twice.
#
# Usage:
#   bash demo/scripts/demo-down.sh

# Deliberately not `-e`: one bad scratch dir must not stop the sweep.
set -uo pipefail

found=0

# Stop the Postgres cluster whose data dir lives under scratch dir $1, if any.
stop_postgres() {
    local data="$1/postgres/data"
    [[ -f "$data/postmaster.pid" ]] || return 0
    if command -v pg_ctl >/dev/null 2>&1 &&
        pg_ctl stop -w -t 10 -D "$data" -m fast >/dev/null 2>&1; then
        echo "    postgres stopped"
        return 0
    fi
    # No pg_ctl, or it refused: fall back to the pid the postmaster recorded.
    local pid
    pid=$(head -1 "$data/postmaster.pid" 2>/dev/null)
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null; then
        echo "    postgres killed (pid $pid)"
    fi
}

# Stop the `sui start` process recorded in scratch dir $1, if it is still alive.
# (localnets.py's state file records its child's pid, not its own.) When
# localnets.py is itself still alive it then sees no live children, leaves its
# loop, and pg_stop's the Postgres it started; stop_postgres covers the case
# where it was killed too.
stop_localnet() {
    local state="$1/localnet.json"
    [[ -f "$state" ]] || return 0
    local pid
    pid=$(jq -r '.pid // empty' "$state" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0

    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || { echo "    localnet stopped (pid $pid)"; return 0; }
        sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null
    echo "    localnet killed after timeout (pid $pid)"
}

# Tear down every scratch dir directly under $1.
sweep_root() {
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        found=1
        echo "▶ tearing down $dir"
        stop_localnet "$dir"
        stop_postgres "$dir"
        rm -rf "$dir" && echo "    removed"
    done < <(find "$1" -maxdepth 1 -type d -name 'attest-demo-*' 2>/dev/null)
}

# run-demo.sh mktemps its scratch dir as /tmp/attest-demo-XXXXXX; sweep $TMPDIR
# too, since that is a different directory on macOS. Resolve each root to its
# physical path first: /tmp is a symlink, and `find` will not descend a symlink
# given as its starting point, so `find /tmp` silently matches nothing.
roots=()
for root in /tmp "${TMPDIR:-/tmp}"; do
    real=$(cd "$root" 2>/dev/null && pwd -P) || continue
    case " ${roots[*]-} " in
        *" $real "*) ;;              # already swept (macOS: /tmp and $TMPDIR can coincide)
        *) roots+=("$real") ;;
    esac
done
for root in ${roots[@]+"${roots[@]}"}; do
    sweep_root "$root"
done

# A SIGKILLed stack can outlive its scratch dir — run-demo.sh may already have
# removed the dir while its Postgres survived — so also reclaim the demo's own
# ports. Only a process whose name matches is stopped; anything else is reported,
# so an unrelated dev server on :3000 is never collateral damage.
#
# $1 = port, $2 = substring the holder's command must contain.
reclaim_port() {
    local port="$1" want="$2" pid comm
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
    [[ -n "$pid" ]] || return 0
    found=1
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    if [[ "$comm" != *"$want"* ]]; then
        echo "! port $port held by pid $pid ($comm) — not ours, leaving it"
        return 0
    fi

    echo "▶ reclaiming :$port from pid $pid"
    # For the postmaster SIGTERM means "smart shutdown": it waits for clients to
    # disconnect and so can hang indefinitely. SIGINT is its fast shutdown.
    if [[ "$want" == postgres ]]; then
        kill -INT "$pid" 2>/dev/null
    else
        kill -TERM "$pid" 2>/dev/null
    fi
    for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || { echo "    stopped"; return 0; }
        sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null
    echo "    killed after timeout"
}

reclaim_port 9000 sui         # fullnode (gRPC)
reclaim_port 9124 sui         # consistent store
reclaim_port 9125 sui         # GraphQL
reclaim_port 5433 postgres    # demo-private Postgres (a system one is on :5432)

# The mvr-side processes, when demo-up.sh started them. Report only: `next dev`
# and a cargo binary are too easy to confuse with a developer's own servers.
for port in 8000 3000; do
    holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
    [[ -n "$holder" ]] || continue
    found=1
    echo "! port $port still held by pid $holder ($(ps -o comm= -p "$holder" 2>/dev/null))"
done

[[ "$found" -eq 0 ]] && echo "▶ nothing to tear down"
exit 0
