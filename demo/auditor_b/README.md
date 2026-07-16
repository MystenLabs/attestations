# Auditor B

> Demo audit firm — the second of two independently-published copies of
> `examples/auditor` (see `demo/README.md`). **Not** in the demo's example trust
> config. Not a real firm.

**Auditor B** publishes the same kind of `Attestation<Audit>` records as
Auditor A: identical schema, different package identity. The demo deliberately
leaves Auditor B *out* of its trust config — our audits exist on-chain, but a
consumer that trusts only Auditor A won't surface them.

That's the point of having us here: trust is anchored to *package identity*, not
to the schema or the mere act of attesting. Same type, different package — and
the consumer treats us differently.
