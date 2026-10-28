# `auditor` — attestation schema template

`auditor` is a copyable template for **becoming an attester**. It defines an
`Audit` attestation type and the `AuditAdminCap` that authorizes issuing and
revoking it. The attester recorded on every `Attestation<Audit>` is *this
package's on-chain identity*, so trust flows from whoever controls the package —
not from the transaction signer. (Why that holds, and how consumers read and
revoke attestations, is the registry's concern — see the registry repo's
`DESIGN.md`.)

This README walks a new auditor through a testnet rehearsal. For agent-guided
setup, naming, custody, browser verification, and a later mainnet rollout, use the
[auditor-onboarding skill](../../skills/auditor-onboarding/SKILL.md).

## What's in the package

The Move code (`sources/audit.move`) defines three things you'll work with:

- **`Audit`** — a completed review: a human-readable description, a link to the
  full report, optionally the report's digest, and its publication date.
- **`AuditAdminCap`** — the single authority that may issue or revoke this
  auditor's attestations, minted at publish and sent to the publisher.
- **`register_audit_display`** — run once after publishing, so your attestations
  render in wallets and explorers with your name, icon, and report links.

## Standing up your own auditor

### 1. Copy and customize the template

Duplicate this package and make it yours. The required changes are small:

- Rename the package: `name` in `Move.toml` and every `auditor::` module/import
  reference in both source and tests (e.g. `module acme_audits::audit;`).
- Verify that the existing `@mysten/attestations` MVR dependency resolves to the
  intended registry deployment on the selected network.
- Set your presentation in `register_audit_display`: your display `name`, your
  report/brand icon (`image_url`), and the report-link template. Get these right
  before publishing: anyone can call `register_audit_display` once the package
  is live, it succeeds only once, and the values can't be changed afterwards.
- Replace this README with your auditing policy, or a link to it — it renders
  on your package's MVR page, so it's what others read to decide to trust you.

Those are the only changes you need. Beyond them, you can extend `Audit` with
extra fields if you want more structured on-chain metadata — just note that the
registry and general consumers only act on the standard Display conventions
(see `CONVENTIONS.md`); anything else is yours to define and interpret.

### 2. Publish and register

Start with a funded testnet address. Verify the registry dependency, build and
test the package, then simulate publishing before approving the transaction:

```sh
sui client switch --env testnet
sui move test --build-env testnet --lint --warnings-are-errors
sui client publish --dry-run
```

After approval, publish with `sui client publish` from a key in your local
keystore. It records the deployment in `Published.toml`; to hold the capabilities
in a multisig, transfer them afterwards (step 3). A later mainnet release
requires its own verified registry deployment, gas, capabilities, and metadata;
never reuse testnet IDs.

From the output, note three ids you'll need:

- your **package id** — listed under *Published Objects*;
- your **`AuditAdminCap`** and the package's **`UpgradeCap`** — under *Created
  Objects*, matched by the object types ending `::audit::AuditAdminCap` and
  `0x2::package::UpgradeCap`. Both were sent to you; custody them in step 3.

You'll also need the shared **`Registry`** object id from the registry's deployment
on the same network. Use it to register your Display, issue reports, and revoke them.

Register your Display once so `Attestation<Audit>` objects render with your name,
icon, and report links (`0xd` is the system display registry):

```sh
sui client call --package <your-pkg> --module audit \
  --function register_audit_display --args <registry-object-id> 0xd
```

Create **PackageInfo** for this deployment and link verified source at an immutable
public revision. Then register an MVR name so the package resolves by name and
its README renders on its page. SuiNS ownership and MVR name management require
mainnet authorization and gas even for a testnet mapping. Naming does not grant
consumer trust. Follow the skill's [MVR registration guide](../../skills/auditor-onboarding/references/mvr-registration.md).

### 3. Custody your capabilities securely

Two objects authorize everything you do — the **`AuditAdminCap`** (issuing and
revoking) and the **`UpgradeCap`** (changing the schema). Treat them like signing
keys: whoever holds them can attest in your name.

We recommend a **multisig** with independently controlled signers for production.
A single-key setup is supported if you accept its compromise/loss risk. Protect
both capabilities, not just UpgradeCap; also choose custody for PackageInfo and
the mainnet MVR AppCap. Create metadata before transferring UpgradeCap, or have
its custodian authorize that step. See the skill's
[signing and custody guide](../../skills/auditor-onboarding/references/signing-and-custody.md).

### 4. Publish reports

Publishing a report requires one `attest_audit` call:

```sh
sui client ptb \
  --move-call <your-pkg>::audit::attest_audit \
    @<admin-cap> @<registry> @<subject> '"<description>"' '"<report-url>"' \
    '<report-hash>' <published-at-ms> @0x6 \
  --sender @<multisig-address> \
  --serialize-unsigned-transaction > attest-tx.b64
```

`<subject>` is the id of the package (or any object) you reviewed, and
`<published-at-ms>` is the publication date in milliseconds since the Unix epoch.
`@0x6` is the `Clock`, from which the registry records when you attested.
`<report-hash>` lets readers check that the report at `<report-url>` is the one
you published: `some("sha256:<hex>")`, with the SHA-256 of the exact file you
host (`shasum -a 256 report.pdf`), or `none` to record no digest. The digest
can't be changed after you attest, so hash the final file, and serve it
byte-for-byte unchanged.
In a `--move-call` target, the package can be its mvr name — e.g. the
`@your-org/audits` you registered — instead of an address; the other arguments
(`@<registry>`, `@<admin-cap>`, `@<subject>`, …) must be addresses.

This writes the unsigned transaction bytes to `attest-tx.b64`, with the multisig
as sender; hand that file to your multisig to sign to threshold and execute.
Use the skill's signing guide to inspect the bytes and verify the returned signature.

To **backfill historical reports**, you can put many `attest_audit` calls in one
PTB — one transaction for your whole back catalogue (a large catalogue may hit
transaction size limits, in which case you can break the PTB into multiple PTBs).

```sh
sui client ptb \
  --move-call <your-pkg>::audit::attest_audit @<admin-cap> @<registry> @<subjectA> '"..."' '"..."' '<hash>' <date> @0x6 \
  --move-call <your-pkg>::audit::attest_audit @<admin-cap> @<registry> @<subjectB> '"..."' '"..."' '<hash>' <date> @0x6 \
  --sender @<multisig-address> \
  --serialize-unsigned-transaction > backfill-tx.b64
```

## Listing your attestations

To see every attestation you've issued, query the selected network's GraphQL
endpoint (`https://graphql.testnet.sui.io/graphql` for the rehearsal, or
`https://graphql.mainnet.sui.io/graphql` for production) for your attestation type.
For `Audit`, that's
`<registry-pkg>::attestations::Attestation<[your-pkg]::audit::Audit>`:

```graphql
query {
  objects(
    filter: { type: "<registry-pkg>::attestations::Attestation<[your-pkg]::audit::Audit>" }
    # add `after: "<endCursor>"` (from pageInfo) to page through large result sets
  ) {
    pageInfo { hasNextPage endCursor }
    nodes {
      address
      asMoveObject { contents { json display { output errors } } }
    }
  }
}
```

Each node is one attestation; `contents.json` carries its `subject`, your
`Audit` fields, and its `revoked_at_ms`, which is `null` until you revoke it.
`contents.display.output` shows the same rendered fields a wallet
or explorer would present, so it's the quickest way to check that your
`register_display` templates interpolate as you intended — `display.errors`
reports any that failed to render. If you've added attestation types in an
upgrade (e.g. `AuditV2`), query each type the same way.

## Revoking an attestation

To withdraw or supersede a report, revoke its attestation with the same
`AuditAdminCap`. Revoking sets the attestation's `revoked_at_ms`, and the
attestation stays at its subject's address — consumers stop treating it as live,
but it stays on-chain and auditable.

Build the revoke transaction the same way you build an attestation:

```sh
sui client ptb \
  --move-call <your-pkg>::audit::revoke_audit @<admin-cap> @<registry> @<subject> @<attestation-id> @0x6 \
  --sender @<multisig-address> \
  --serialize-unsigned-transaction > revoke-tx.b64
```

`<subject>` is the subject the attestation is about. `<attestation-id>` is the
attestation to revoke, passed with `@` so it resolves as the `Receiving`
argument. Sign and execute through your multisig, as with an attestation
transaction.

## Learn more

- Attester-identity model and registry design — the registry repo's `DESIGN.md`.
- Display field conventions (`name`, `description`, `image_url`, `link`,
  `link_hash`, `published_at`) — `CONVENTIONS.md`.
