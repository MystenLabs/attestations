# Example Auditor

> Sample auditor package for the MVR attestation demo. Not a real audit firm.

**Example Auditor** is a Move security firm. We review Sui packages and publish
the results on-chain as `Attestation<Audit>` records anchored to this package's
identity, so anyone can verify — from bytecode, not a website — that an audit
came from us.

## What we attest

- **`Audit`** — a completed review, with a score out of 100 and a link to the
  full report.
- **`AuditV2`** — our richer schema (added in a package upgrade): adds a report
  link and a `requires` list, so an audit can be made conditional on audits of
  the package's dependencies. If a required dependency audit is revoked, ours is
  automatically considered ineffective.

## Reading our attestations

Audits issued by Example Auditor show up under **Security → Audits** on a
package's MVR page. A revoked or superseded audit is shown but de-emphasized.

## Contact

- Reports: https://audits.example.com
- This is demo content; see the attestation-registry repo for how it's produced.
