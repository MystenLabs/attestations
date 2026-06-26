# Example Security Scanner

> Sample vulnerability-disclosure package for the MVR attestation demo. Not a
> real security service.

**Example Security Scanner** publishes vulnerability disclosures for Sui
packages as on-chain `Attestation<Vulnerability>` records anchored to this
package's identity.

## What we attest

- **`Vulnerability`** — a disclosed issue, with a **CVSS** base score (0–10), a
  CVE identifier, and a description. Polarity is `negative`, so consumers treat
  it as a warning rather than an endorsement.

## How disclosures surface

A disclosure shows up under **Security → Vulnerabilities** on the affected
package's MVR page, sorted by severity. Because vulnerabilities **propagate to
dependents**, a disclosure on a library also surfaces (as inherited) on every
package that depends on it — until it is revoked (e.g. patched).

## Contact

- Disclosures: https://scanner.example.com
- This is demo content; see the attestation-registry repo for how it's produced.
