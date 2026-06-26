# Auditor A

> Demo audit firm — one of two independently-published copies of
> `examples/auditor` (see `demo/README.md`). **Trusted** in the demo's example
> trust config. Not a real firm.

**Auditor A** reviews Sui packages and publishes the results on-chain as
`Attestation<Audit>` and `Attestation<AuditV2>` records anchored to this
package's identity. A consumer that trusts Auditor A's package address surfaces
these audits on the packages we've reviewed — verifiable from bytecode, not from
a website.

We issue and revoke audits under a single `AuditAdminCap` held by the firm, and
we've upgraded our schema to `AuditV2` (a richer report) over time.
