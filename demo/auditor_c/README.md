# Auditor C

> Demo audit firm — a third independently-published copy of `examples/auditor`
> (see `demo/README.md`), created by following that template's onboarding guide.
> **In** the demo's example trust config. Not a real firm.

**Auditor C** issues `Attestation<Audit>` records about packages it has reviewed.
Like Auditor A, it is in the demo's trust config, so a consumer that trusts it
surfaces its audits alongside Auditor A's on a package's Security tab.

## Auditing policy (illustrative)

- We publish an attestation only after a manual review of the package's source.
- Each attestation links to the full written report.
- We revoke an attestation when a later finding supersedes it.

Trust is anchored to *package identity*: these audits carry Auditor C's package
address, and a consumer decides whether to trust that address.
