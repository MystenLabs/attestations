#!/usr/bin/env python3
"""Print the attestation state on a localnet as readable, stable text.

It reads the chain the way a consumer would. For every subject it derives the
subject's active box address and revoked address off-chain, from the registry
and subject ids, and lists the attestations each one owns through GraphQL, with
their data and rendered Display. Every id is replaced with the name of the
package or object it belongs to, so the output is the same on every run and
can be diffed against a committed copy (e2e/expected.txt).

Subjects are the ones named in the registry's Attested and Revoked events, plus
any passed with --subject. For each one it checks that every attestation the
events announce is at one of the subject's two addresses, which is what a
consumer relies on; a mismatch shows up as a line starting with `!!`.

Usage (e2e/run.sh calls it):
  python3 e2e/snapshot.py --graphql URL --rpc URL --pubfile PATH \
      --registry ID --sender ADDRESS [--name ADDRESS=LABEL ...] [--subject NAME ...]

Needs Python 3.11+ (tomllib) and nothing outside the standard library.
"""

import argparse
import hashlib
import json
import re
import sys
import time
import tomllib
import urllib.request
from pathlib import Path

ADDRESS = re.compile(r"0x[0-9a-f]{64}")
# GraphQL's maximum page size. No address or event stream in the e2e run comes
# close; if one ever does, the snapshot fails rather than silently truncating.
PAGE = 50
# Until the indexer has committed anything, GraphQL reports this as the latest
# checkpoint, so it must not be read as "caught up".
NO_CHECKPOINT = 2**63 - 1

HEADER = """\
# On-chain state left by e2e/run.sh, read back by e2e/snapshot.py.
#
# For each subject: the attestations at its active box and at its revoked
# address (both derived off-chain from the registry and subject ids), with
# their data and rendered Display. Then every event the registry emitted, in
# order. Ids are replaced with names: a package's directory name, `name@vN` for
# version N of an upgraded package, or a label given by e2e/run.sh.
#
# Generated; do not edit. To accept a change: UPDATE_SNAPSHOT=1 bash e2e/run.sh
"""


def normalize(address):
    """An address as GraphQL prints it: 0x and 64 lowercase hex digits."""
    return "0x" + address.lower().removeprefix("0x").rjust(64, "0")


# === Box addresses ===
#
# Off-chain mirror of `derived_object::derive_address(registry,
# BoxKey { subject, revoked })`, which hashes the key as a dynamic-field name:
#   blake2b256(0xf0 || parent || len(key) as u64 LE || bcs(key) || bcs(key type))
# where the key is `0x2::derived_object::DerivedObjectKey<BoxKey>(BoxKey { .. })`.


def uleb128(n):
    out = bytearray()
    while True:
        byte, n = n & 0x7F, n >> 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def bcs_identifier(name):
    return uleb128(len(name)) + name.encode()


def bcs_struct_tag(address, module, name, type_params=()):
    # A `TypeTag::Struct` (variant 7) wrapping the struct tag.
    out = b"\x07" + bytes.fromhex(normalize(address)[2:])
    out += bcs_identifier(module) + bcs_identifier(name) + uleb128(len(type_params))
    return out + b"".join(type_params)


def box_address(registry, registry_pkg, subject, revoked):
    # DerivedObjectKey is a one-field struct, so its BCS is just the BoxKey's:
    # the subject ID followed by the bool.
    key = bytes.fromhex(normalize(subject)[2:]) + (b"\x01" if revoked else b"\x00")
    key_type = bcs_struct_tag(
        "0x2", "derived_object", "DerivedObjectKey",
        [bcs_struct_tag(registry_pkg, "attestations", "BoxKey")],
    )
    digest = hashlib.blake2b(digest_size=32)
    digest.update(b"\xf0")  # HashingIntentScope::ChildObjectId
    digest.update(bytes.fromhex(normalize(registry)[2:]))
    digest.update(len(key).to_bytes(8, "little"))
    digest.update(key)
    digest.update(key_type)
    return "0x" + digest.hexdigest()


# === Talking to the localnet ===


class Chain:
    def __init__(self, graphql_url, rpc_url):
        self.graphql_url = graphql_url
        self.rpc_url = rpc_url

    @staticmethod
    def _post(url, payload):
        request = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"content-type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())

    def query(self, query, **variables):
        body = self._post(self.graphql_url, {"query": query, "variables": variables})
        if body.get("errors"):
            sys.exit("GraphQL error:\n" + json.dumps(body["errors"], indent=2))
        return body["data"]

    def rpc(self, method, *params):
        body = self._post(
            self.rpc_url,
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)},
        )
        if "error" in body:
            sys.exit(f"JSON-RPC error from {method}: {body['error']}")
        return body["result"]

    def wait_for_indexer(self, sender, timeout=120):
        """Block until GraphQL has indexed `sender`'s last transaction.

        Every transaction in the e2e run is sent from the one client address,
        so once its last one is indexed, everything is.
        """
        deadline = time.monotonic() + timeout

        def wait(what, ready):
            while (value := ready()) is None:
                if time.monotonic() > deadline:
                    sys.exit(f"timed out after {timeout}s waiting for {what}")
                time.sleep(0.5)
            return value

        last = self.rpc(
            "suix_queryTransactionBlocks",
            {"filter": {"FromAddress": sender}, "options": {}}, None, 1, True,
        )["data"]
        if not last:
            sys.exit(f"{sender} has sent no transactions")
        digest = last[0]["digest"]

        # A transaction is executed before it is in a checkpoint, so its
        # checkpoint can be missing for a moment.
        def checkpoint_of_last():
            checkpoint = self.rpc("sui_getTransactionBlock", digest, {}).get("checkpoint")
            return None if checkpoint is None else int(checkpoint)

        target = wait(f"transaction {digest} to be checkpointed", checkpoint_of_last)

        def indexed():
            seen = self.query("{ checkpoint { sequenceNumber } }")["checkpoint"]["sequenceNumber"]
            return True if target <= seen < NO_CHECKPOINT else None

        wait(f"GraphQL to index checkpoint {target}", indexed)


EVENTS = """
query($type: String!, $after: String) {
  events(first: %d, after: $after, filter: { type: $type }) {
    pageInfo { hasNextPage endCursor }
    nodes { contents { type { repr } json } }
  }
}""" % PAGE

BOXES = """
query($active: SuiAddress!, $revoked: SuiAddress!, $type: String!) {
  activeObject: object(address: $active) { asMoveObject { contents { type { repr } } } }
  revokedObject: object(address: $revoked) { asMoveObject { contents { type { repr } } } }
  active: address(address: $active) { ...attestations }
  revoked: address(address: $revoked) { ...attestations }
}

fragment attestations on Address {
  objects(first: %d, filter: { type: $type }) {
    pageInfo { hasNextPage }
    nodes { contents { type { repr } json display { output errors } } }
  }
}""" % PAGE


def registry_events(chain, registry_pkg):
    """(kind, schema type, subject) for each registry event, in emission order."""
    events, after = [], None
    while True:
        page = chain.query(EVENTS, type=f"{registry_pkg}::attestations", after=after)["events"]
        for node in page["nodes"]:
            kind, schema = re.fullmatch(
                r"0x[0-9a-f]+::attestations::(\w+)<(.+)>", node["contents"]["type"]["repr"]
            ).groups()
            events.append((kind, schema, normalize(node["contents"]["json"]["subject"])))
        if not page["pageInfo"]["hasNextPage"]:
            return events
        after = page["pageInfo"]["endCursor"]


def subject_state(chain, registry, registry_pkg, subject):
    active = box_address(registry, registry_pkg, subject, revoked=False)
    revoked = box_address(registry, registry_pkg, subject, revoked=True)
    data = chain.query(
        BOXES, active=active, revoked=revoked,
        type=f"{registry_pkg}::attestations::Attestation",
    )

    def object_type(obj):
        return obj and obj["asMoveObject"]["contents"]["type"]["repr"]

    def attestations(owner):
        objects = data[owner]["objects"]
        if objects["pageInfo"]["hasNextPage"]:
            sys.exit(f"more than {PAGE} attestations at one address; e2e/snapshot.py needs paging")
        return [node["contents"] for node in objects["nodes"]]

    return {
        "active": attestations("active"),
        "revoked": attestations("revoked"),
        "active_object": object_type(data["activeObject"]),
        "revoked_object": object_type(data["revokedObject"]),
    }


# === Names ===


class Names:
    """Maps addresses to readable labels, numbering any it doesn't know."""

    def __init__(self):
        self.labels = {}
        self.unnamed = {}

    def add(self, address, label):
        self.labels[normalize(address)] = label

    def address_of(self, name):
        """The address for a label, or `name` itself if it is an address."""
        for address, label in self.labels.items():
            if label == name:
                return address
        if re.fullmatch(r"0x[0-9a-fA-F]+", name):
            return normalize(name)
        sys.exit(f"unknown subject {name!r}: not a known name or an address")

    def label(self, address):
        address = normalize(address)
        if address in self.labels:
            return self.labels[address]
        if address not in self.unnamed:
            self.unnamed[address] = f"<unnamed-{len(self.unnamed) + 1}>"
        return self.unnamed[address]

    def rename(self, text):
        return ADDRESS.sub(lambda match: self.label(match.group(0)), text)


def load_packages(pubfile, names):
    """Name every package in the pubfile; return the registry package's id."""
    registry_pkg = None
    for pkg in tomllib.loads(Path(pubfile).read_text())["published"]:
        name = Path(pkg["source"]["local"]).name
        if pkg["version"] > 1:
            names.add(pkg["original-id"], f"{name}@v1")
            names.add(pkg["published-at"], f"{name}@v{pkg['version']}")
        else:
            names.add(pkg["original-id"], name)
        if name == "attestations":
            # Types are named by the package version that defined them, and
            # Attestation and BoxKey are in the first.
            registry_pkg = normalize(pkg["original-id"])
    if registry_pkg is None:
        sys.exit(f"no packages/attestations entry in {pubfile}")
    return registry_pkg


# === Rendering ===


def schema_of(attestation_type):
    """`T` from `0x…::attestations::Attestation<T>`."""
    return re.fullmatch(r"0x[0-9a-f]+::attestations::Attestation<(.+)>", attestation_type).group(1)


def value_text(value, names):
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return names.rename(text)


def render_fields(heading, fields, names, indent):
    if not fields:
        return [f"{indent}{heading}: none"]
    lines = [f"{indent}{heading}:"]
    lines += [f"{indent}  {key}: {value_text(value, names)}" for key, value in fields.items()]
    return lines


def render_attestation(contents, subject, names):
    lines = [f"  {names.rename(schema_of(contents['type']['repr']))}"]
    if normalize(contents["json"]["subject"]) != subject:
        lines.append(f"    !! its subject field is {names.label(contents['json']['subject'])}")
    lines += render_fields("data", contents["json"]["data"], names, "    ")
    display = contents["display"]
    lines += render_fields("display", display and display["output"], names, "    ")
    if display and display["errors"]:
        lines += render_fields("display errors", display["errors"], names, "    ")
    return lines


def render_location(heading, object_type, attestations, subject, names):
    found = f"{names.rename(object_type)} object" if object_type else "no object"
    lines = [f"{heading} ({found})"]
    rendered = sorted(render_attestation(a, subject, names) for a in attestations)
    lines += [line for block in rendered for line in block] or ["  (none)"]
    return lines


def render_subject(subject, state, events, names):
    attested = sum(1 for kind, _, s in events if kind == "Attested" and s == subject)
    revoked = sum(1 for kind, _, s in events if kind == "Revoked" and s == subject)
    lines = [f"== {names.label(subject)} ==", f"events: {attested} attested, {revoked} revoked", ""]

    missing = attested - len(state["active"]) - len(state["revoked"])
    if missing:
        lines.append(f"!! {missing} attestation(s) announced by events are at neither address")
    if revoked != len(state["revoked"]):
        lines.append(f"!! {revoked} revoked by events, but {len(state['revoked'])} at the revoked address")

    lines += render_location("active box", state["active_object"], state["active"], subject, names)
    lines.append("")
    lines += render_location("revoked address", state["revoked_object"], state["revoked"], subject, names)
    return lines


def render_events(events, names):
    rows = [(kind, names.rename(schema), names.label(subject)) for kind, schema, subject in events]
    width = max((len(schema) for _, schema, _ in rows), default=0)
    lines = ["== events, in order =="]
    lines += [f"{kind:<8}  {schema:<{width}}  {subject}" for kind, schema, subject in rows]
    return lines or ["  (none)"]


def consistent(state, subject, events):
    attested = sum(1 for kind, _, s in events if kind == "Attested" and s == subject)
    revoked = sum(1 for kind, _, s in events if kind == "Revoked" and s == subject)
    return (len(state["active"]) + len(state["revoked"]), len(state["revoked"])) == (attested, revoked)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--graphql", required=True, help="GraphQL endpoint URL")
    parser.add_argument("--rpc", required=True, help="fullnode JSON-RPC URL")
    parser.add_argument("--pubfile", required=True, help="the e2e run's Pub.localnet.toml")
    parser.add_argument("--registry", required=True, help="the Registry object id")
    parser.add_argument("--sender", required=True, help="the address that sent every transaction")
    parser.add_argument("--name", action="append", default=[], metavar="ADDRESS=LABEL",
                        help="name an address that isn't a package")
    parser.add_argument("--subject", action="append", default=[], metavar="NAME",
                        help="also show this subject (a name or an address), even with no events")
    args = parser.parse_args()

    chain = Chain(args.graphql, args.rpc)
    chain.wait_for_indexer(args.sender)

    names = Names()
    registry_pkg = load_packages(args.pubfile, names)
    names.add(args.registry, "registry")
    for pair in args.name:
        address, label = pair.split("=", 1)
        names.add(address, label)

    events = registry_events(chain, registry_pkg)
    subjects = list(dict.fromkeys([s for _, _, s in events] + [names.address_of(s) for s in args.subject]))

    states = {}
    for subject in subjects:
        # The consistent store that serves owned objects can trail the indexer
        # by a moment, so give a mismatch with the events a few chances first.
        for _ in range(20):
            states[subject] = subject_state(chain, args.registry, registry_pkg, subject)
            if consistent(states[subject], subject, events):
                break
            time.sleep(0.5)

    blocks = [render_subject(s, states[s], events, names) for s in subjects]
    blocks.append(render_events(events, names))
    print(HEADER)
    print("\n\n".join("\n".join(block) for block in blocks))


if __name__ == "__main__":
    main()
