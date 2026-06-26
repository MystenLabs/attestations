# Copyright (c) Mysten Labs, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Vendored from MystenLabs/jellyfish
# (crates/jellyfish-cli/tests/scripts/localnets.py) and adapted for this demo:
# the localnet runs `--with-faucet`, fullnode readiness is a stdlib JSON-RPC
# check (no `grpcurl` dependency), and the consistent-store readiness gate is
# dropped (GraphQL readiness already implies it). The point of using it is that
# `serve` owns the Postgres it starts and tears it down on exit/signal, so the
# demo leaves no orphaned indexer Postgres behind.

import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from threading import Thread

DEADLINE_SECONDS = 90
POLL_SECONDS = 0.1
NETWORK_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")

stop = False
children = []


def request(url, payload):
    encoded = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=encoded,
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=1) as response:
        return json.loads(response.read().decode())


def fn_ready(port):
    # JSON-RPC readiness (stdlib urllib) so the demo needs no `grpcurl`. The
    # fullnode serves JSON-RPC on its `--fullnode-rpc-port`; a chain identifier
    # means genesis is up.
    body = request(
        f"http://127.0.0.1:{port}",
        {"jsonrpc": "2.0", "id": 1, "method": "sui_getChainIdentifier", "params": []},
    )
    return bool(body.get("result"))


def faucet_ready(port):
    # The faucet binds its TCP port once it is serving; a successful connect is
    # enough for the demo's subsequent `sui client faucet` to land.
    return not port_closed(port)


def gql_ready(port):
    body = request(
        f"http://127.0.0.1:{port}/graphql",
        {"query": "{ chainIdentifier }"},
    )
    return bool(body.get("data", {}).get("chainIdentifier"))


def wait_until(label, ready):
    deadline = time.monotonic() + DEADLINE_SECONDS
    last_error = None

    while True:
        try:
            if ready():
                return None
        except Exception as error:
            last_error = error

        if live_children() != len(children):
            return f"{label}: localnet exited early"

        if time.monotonic() >= deadline:
            return f"{label}: timed out: {last_error}"

        time.sleep(POLL_SECONDS)


def parse_network(value):
    parts = value.split(",")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("expected NAME,FULLNODE,CONSISTENT,GRAPHQL")

    name = parts[0]
    if not NETWORK_NAME_RE.fullmatch(name):
        raise argparse.ArgumentTypeError(
            "NAME must match [a-z][a-z0-9_]* so it can be used as a database name"
        )

    return parts


def pg_run(args, **kwargs):
    env = os.environ.copy()
    env["PGCONNECT_TIMEOUT"] = "5"
    return subprocess.run(args, env=env, timeout=30, **kwargs)


def pg_start(root, port):
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)

    pg_run(
        [
            "initdb",
            *("-D", root / "data"),
            *("-A", "trust"),
            *("-U", "postgres"),
            *("-E", "UTF8"),
            "--no-locale",
            "--no-sync",
            "--no-instructions",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )

    pg_run(
        [
            *("pg_ctl", "start", "-w"),
            *("-t", "30"),
            *("-D", root / "data"),
            *("-l", root / "postgres.log"),
            *("-o", f"-p {port} -h 127.0.0.1 -c unix_socket_directories="),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def pg_createdb(port, database):
    pg_run(
        [
            "createdb",
            "--host=127.0.0.1",
            *("--port", port),
            "--username=postgres",
            "--no-password",
            database,
        ],
        check=True,
    )


def pg_stop(root):
    data = root / "data"
    if not data.exists():
        return

    try:
        pg_run(
            [
                *("pg_ctl", "stop", "-w"),
                *("-t", "10"),
                *("-D", data),
                *("-m", "fast"),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def live_children():
    return sum(1 for _name, child in children if child.poll() is None)


def terminate_children():
    for _name, child in children:
        if child.poll() is None:
            child.terminate()

    deadline = time.monotonic() + 5
    while live_children() > 0 and time.monotonic() < deadline:
        time.sleep(0.05)

    for _name, child in children:
        if child.poll() is None:
            child.kill()


def handle_signal(_signum, _frame):
    global stop
    stop = True
    terminate_children()


def serve(args):
    ready_file = Path(args.ready)
    ready_file.unlink(missing_ok=True)

    failed_file = ready_file.with_suffix(ready_file.suffix + ".failed")
    failed_file.unlink(missing_ok=True)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    pg_root = Path("postgres")
    # `sui start --force-regenesis` mkdtemp's its node dbs (authorities_db,
    # consensus_db, full_node_db) under $TMPDIR and never removes them — across
    # runs they accumulated to tens of GB. Redirect each localnet's $TMPDIR into
    # this dir so teardown can sweep them with the rest of our scratch state.
    sui_tmp_root = Path("sui-tmp")

    try:
        pg_start(pg_root, args.pg_port)

        for name, fullnode, consistent, graphql in args.network:
            pg_createdb(args.pg_port, name)
            sui_tmp = sui_tmp_root / name
            sui_tmp.mkdir(parents=True, exist_ok=True)
            env = os.environ.copy()
            env["TMPDIR"] = str(sui_tmp.resolve())
            child = subprocess.Popen(
                [
                    *("sui", "start", "--force-regenesis", "--quiet"),
                    *("--fullnode-rpc-port", fullnode),
                    f"--with-faucet=127.0.0.1:{args.faucet_port}",
                    f"--with-indexer=postgres://postgres@127.0.0.1:{args.pg_port}/{name}",
                    f"--with-consistent-store=127.0.0.1:{consistent}",
                    f"--with-graphql=127.0.0.1:{graphql}",
                ],
                env=env,
            )

            Path(f"{name}.json").write_text(
                json.dumps(
                    {
                        "pid": child.pid,
                        "ports": {
                            "fullnode": fullnode,
                            "consistent": consistent,
                            "graphql": graphql,
                            "faucet": args.faucet_port,
                        },
                    }
                )
            )

            children.append((name, child))
            print(f"started {name}", flush=True)

        # The consistent store still starts (GraphQL needs it); we just don't
        # gate on it directly — a ready GraphQL implies a ready consistent store.
        checks = [(f"faucet", lambda p=args.faucet_port: faucet_ready(p))]
        for name, fn, _cs, gql in args.network:
            checks.append((f"{name} FN", lambda p=fn: fn_ready(p)))
            checks.append((f"{name} GQL", lambda p=gql: gql_ready(p)))

        errors = []

        def check(label, ready):
            error = wait_until(label, ready)
            if error is not None:
                errors.append(error)

        threads = [Thread(target=check, args=check_args) for check_args in checks]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        if errors:
            failed_file.write_text("\n".join(errors) + "\n")
            return 1

        ready_file.write_text("ready\n")
        while not stop and live_children() > 0:
            time.sleep(1)

        return 0
    except Exception as error:
        message = f"failed to start localnets: {error}\n"

        pg_log = pg_root / "postgres.log"
        if pg_log.exists():
            message += f"\nPOSTGRES:\n{pg_log.read_text(errors='replace')}"

        failed_file.write_text(message)
        raise
    finally:
        terminate_children()
        pg_stop(pg_root)
        # Children are dead now, so their node-db temp dirs are free to remove.
        shutil.rmtree(sui_tmp_root, ignore_errors=True)


def port_closed(port):
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=0.2):
            return False
    except OSError:
        return True


def kill(args):
    state = json.loads(Path(f"{args.name}.json").read_text())
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(state["pid"]), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        os.kill(state["pid"], signal.SIGTERM)

    deadline = time.monotonic() + DEADLINE_SECONDS
    while time.monotonic() < deadline:
        if all(port_closed(port) for port in state["ports"].values()):
            return 0
        time.sleep(POLL_SECONDS)

    print(f"{args.name}: timed out waiting for ports to close")
    return 1


def ready(args):
    ready_file = Path(args.ready)
    failed_file = ready_file.with_suffix(ready_file.suffix + ".failed")
    deadline = time.monotonic() + DEADLINE_SECONDS

    while True:
        if ready_file.exists():
            return 0
        if failed_file.exists():
            sys.stdout.write(failed_file.read_text())
            return 1
        if time.monotonic() >= deadline:
            print("timed out waiting for localnets")
            return 1
        time.sleep(POLL_SECONDS)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--ready", required=True)
    serve_parser.add_argument("--pg-port", required=True)
    serve_parser.add_argument("--faucet-port", required=True)
    serve_parser.add_argument(
        "--network",
        action="append",
        required=True,
        type=parse_network,
        help="NAME,FULLNODE,CONSISTENT,GRAPHQL",
    )
    serve_parser.set_defaults(func=serve)

    ready_parser = subparsers.add_parser("ready")
    ready_parser.add_argument("ready")
    ready_parser.set_defaults(func=ready)

    kill_parser = subparsers.add_parser("kill")
    kill_parser.add_argument("name")
    kill_parser.set_defaults(func=kill)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
