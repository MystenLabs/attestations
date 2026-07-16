# `auditor` — attestation schema template

`auditor` is a copyable template for **becoming an attester**. It defines an
`Audit` attestation type and the `AuditAdminCap` that authorizes issuing and
revoking it. The attester recorded on every `Attestation<Audit>` is *this
package's on-chain identity*, so trust flows from whoever controls the package —
not from the transaction signer. (Why that holds, and how consumers read and
revoke attestations, is the registry's concern — see the registry repo's
`DESIGN.md`.)

This README walks a new auditor from the template to publishing live reports.

## What's in the package

The Move code (`sources/audit.move`) defines three things you'll work with:

- **`Audit`** — a completed review: a human-readable description, a link to the
  full report, and the report's publication date.
- **`AuditAdminCap`** — the single authority that may issue or revoke this
  auditor's attestations, minted at publish and sent to the publisher.
- **`register_audit_display`** — run once after publishing, so your attestations
  render in wallets and explorers with your name, icon, and report links.

## Standing up your own auditor

### 1. Copy and customize the template

Duplicate this package and make it yours. The required changes are small:

- Rename the package — `name` in `Move.toml`, and the `auditor::` prefix on the
  `module` line in `audit.move` (e.g. `module acme_audits::audit;`).
- Point the `attestations` dependency in `Move.toml` at the published registry
  (via its mvr name) rather than the local path this template uses.
- Set your presentation in `register_audit_display`: your display `name`, your
  report/brand icon (`image_url`), and the report-link template.
- Replace this README with your auditing policy, or a link to it — it renders
  on your package's MVR page, so it's what others read to decide to trust you.

Those are the only changes you need. Beyond them, you can extend `Audit` with
extra fields if you want more structured on-chain metadata — just note that the
registry and general consumers only act on the standard Display conventions
(see `CONVENTIONS.md`); anything else is yours to define and interpret.

### 2. Publish and register

Publish the package on mainnet:

```sh
sui client switch --env mainnet
sui client publish
```

From the output, note three ids you'll need:

- your **package id** — listed under *Published Objects*;
- your **`AuditAdminCap`** and the package's **`UpgradeCap`** — under *Created
  Objects*, matched by the object types ending `::audit::AuditAdminCap` and
  `0x2::package::UpgradeCap`. Both were sent to you; custody them in step 3.

You'll also need the registry's shared **`Registry` object id** from its mainnet
deployment — used in the call below and every time you issue.

Register your Display once so `Attestation<Audit>` objects render with your name,
icon, and report links (`0xd` is the system display registry):

```sh
sui client call --package <your-pkg> --module audit \
  --function register_audit_display --args <registry-object-id> 0xd
```

Finally, register **a mvr name** for the package and link its git source, so it
resolves by name and your README renders on its page — see the
[mvr docs](https://docs.suins.io/move-registry).

### 3. Custody your capabilities securely

Two objects authorize everything you do — the **`AuditAdminCap`** (issuing and
revoking) and the **`UpgradeCap`** (changing the schema). Treat them like signing
keys: whoever holds them can attest in your name.

Hold them in a **multisig** (≥ 2-of-N, kept cold), not a single hot key. Set one
up and transfer both caps to its address; from then on, issuing and revoking are
transactions your multisig signs and executes. One tool for managing the
multisig and for proposing, signing, and executing those transactions is
[Sagat](https://docs.sui.io/sui-stack/sagat), Mysten's Sui multisig manager.

### 4. Publish reports

Publishing a report requires one `attest_audit` call:

```sh
sui client ptb \
  --move-call <your-pkg>::audit::attest_audit \
    @<admin-cap> @<registry> @<subject> '"<description>"' '"<report-url>"' <published-at-ms> \
  --sender <multisig-address> \
  --serialize-unsigned-transaction > attest-tx.b64
```

`<subject>` is the id of the package (or any object) you reviewed, and
`<published-at-ms>` is the publication date in milliseconds since the Unix epoch.
In a `--move-call` target, the package can be its mvr name — e.g. the
`@your-org/audits` you registered — instead of an address; the other arguments
(`@<registry>`, `@<admin-cap>`, `@<subject>`, …) must be addresses.

This writes the unsigned transaction bytes to `attest-tx.b64`, with the multisig
as sender; hand that file to your multisig to sign to threshold and execute (for
example by proposing it in Sagat).

To **backfill historical reports**, you can put many `attest_audit` calls in one
PTB — one transaction for your whole back catalogue (a large catalogue may hit
transaction size limits, in which case you can break the PTB into multiple PTBs).

```sh
sui client ptb \
  --move-call <your-pkg>::audit::attest_audit @<admin-cap> @<registry> @<subjectA> '"..."' '"..."' <date> \
  --move-call <your-pkg>::audit::attest_audit @<admin-cap> @<registry> @<subjectB> '"..."' '"..."' <date> \
  --sender <multisig-address> \
  --serialize-unsigned-transaction > backfill-tx.b64
```

## Listing your attestations

To see every attestation you've issued, query the mainnet GraphQL endpoint
(`https://graphql.mainnet.sui.io/graphql`) for objects of your attestation type.
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

Each node is one attestation; `contents.json` carries its `subject` and your
`Audit` fields. `contents.display.output` shows the same rendered fields a wallet
or explorer would present, so it's the quickest way to check that your
`register_display` templates interpolate as you intended — `display.errors`
reports any that failed to render. If you've added attestation types in an
upgrade (e.g. `AuditV2`), query each type the same way.

## Revoking an attestation

To withdraw or supersede a report, revoke its attestation with the same
`AuditAdminCap`. The registry stores each subject's attestations in a *box*, and
revoking moves the attestation from the subject's *active* box to its *revoked*
box — consumers stop treating it as live, but it stays on-chain and auditable.

Revoking works on that box, so it must exist (issuing doesn't need it).
`create_box` is idempotent, so just run it — no cap needed, so execute it
directly (`<registry-pkg>` is the registry's package id):

```sh
sui client ptb --move-call <registry-pkg>::attestations::create_box @<registry> @<subject>
```

Then build the revoke transaction the same way you build an attestation:

```sh
sui client ptb \
  --move-call <your-pkg>::audit::revoke_audit @<admin-cap> @<active-box> @<attestation-id> \
  --sender <multisig-address> \
  --serialize-unsigned-transaction > revoke-tx.b64
```

`<active-box>` is the box that owns the attestation — its current owner, which
`sui client object <attestation-id>` shows. `<attestation-id>` is the attestation
to revoke, passed with `@` so it resolves as the `Receiving` argument. Sign and
execute through your multisig, as with an attestation transaction.

## Learn more

- Attester-identity model and registry design — the registry repo's `DESIGN.md`.
- Display field conventions (`name`, `description`, `image_url`, `link`,
  `published_at`) — `CONVENTIONS.md`.
