# Issue, revoke, and verify audits

Use the deployment's `NETWORK`, `REGISTRY`, `CORE_ORIGINAL`, `AUDITOR_PKG`,
`ADMIN_CAP`, and `RECORDS`. Set `ISSUER` to the current AuditAdminCap owner, not
necessarily the publisher. Verify ownership and gas on this network first.

## 1. Prepare the claim

For a testnet rehearsal, use the auditor package itself or a company-controlled
sample as `SUBJECT`. Mark the claim and its linked report as a test example with
no security assurance. Obtain approval even for test claims: they remain on-chain.
Do not attach fictitious audits to unrelated third-party packages.

For production, ask the auditor to confirm:

- The exact subject package ID and version reviewed, on the selected network.
  An MVR name without a version resolves latest; do not silently attest to an
  upgrade that was outside the audit. The schema stores an ID, not a version range.
- Accurate claim wording, the final report URL, and the report's publication
  timestamp in Unix **milliseconds**. The registry separately timestamps issuance.
- Whether to store the report digest. Hash the exact final hosted file, not its
  URL or an earlier draft. Ensure the downloaded bytes match the digest.

Set `DESCRIPTION`, `REPORT_URL`, and `PUBLISHED_MS` from these approved values.
Use `REPORT_HASH_ARG=none` if no digest is available. To include SHA-256:

```sh
: "${REPORT_FILE:?Set the path to the final report file}"
REPORT_SHA=$(python3 - "$REPORT_FILE" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
REPORT_HASH_ARG="some(\"sha256:$REPORT_SHA\")"
```

A digest supports integrity checking, not report authenticity by itself. Keep
the URL stable and the bytes unchanged. Do not upload confidential reports
without the company's approval; on-chain descriptions and links are public.

## 2. Issue the approved claim

Validate the timestamp and encode text as quoted arguments; do not interpolate
user text into a shell program or use `eval`:

```sh
[[ "$PUBLISHED_MS" =~ ^[0-9]+$ ]]
DESC_ARG=$(jq -cn --arg text "$DESCRIPTION" '$text')
URL_ARG=$(jq -cn --arg text "$REPORT_URL" '$text')
sui client --client.env "$NETWORK" ptb --sender "@$ISSUER" \
  --move-call "$AUDITOR_PKG::audit::attest_audit" \
    "@$ADMIN_CAP" "@$REGISTRY" "@$SUBJECT" "$DESC_ARG" "$URL_ARG" \
    "$REPORT_HASH_ARG" "$PUBLISHED_MS" @0x6 \
  --dry-run
```

Review the simulation, then follow
[signing and custody](signing-and-custody.md) for local or external signing of the
saved bytes. Execute only after approval. Save the successful execution JSON
as `attest.json` in this operation's records directory. Extract the created
`CORE_ORIGINAL::attestations::Attestation<AUDITOR_ORIGINAL::audit::Audit>` object's
ID and record it with the subject and digest. On a fresh publish,
`AUDITOR_ORIGINAL` equals `AUDITOR_PKG`; types remain anchored after upgrades.

For the testnet rehearsal, repeat with a second explicitly labeled example and
separate result file. Record `LIVE_ID` and `REVOKED_ID`; do not overwrite the
first result. The following step revokes only the second claim. Issuing is not
idempotent: re-running a successful call creates another claim.

## 3. Revoke an example or superseded report

Confirm the exact claim, its schema, subject, and current status before revoking:

```sh
sui client --client.env "$NETWORK" object "$REVOKED_ID" --json
sui client --client.env "$NETWORK" ptb --sender "@$ISSUER" \
  --move-call "$AUDITOR_PKG::audit::revoke_audit" \
    "@$ADMIN_CAP" "@$REGISTRY" "@$SUBJECT" "@$REVOKED_ID" @0x6 \
  --dry-run
```

Follow the saved-byte signing flow and execute only after approval.
Revocation sets `revoked_at_ms`; it neither
deletes the object nor frees its ID for reuse. A correction needs a new claim,
and normally revocation of the incorrect one. Do not revoke an arbitrary real
audit just to demonstrate the flow.

## 4. Inspect chain state and Display

The GraphQL endpoints are `https://graphql.testnet.sui.io/graphql` and
`https://graphql.mainnet.sui.io/graphql`. In the rehearsal, query the two IDs:

```sh
QUERY=$(jq -n --arg live "$LIVE_ID" --arg revoked "$REVOKED_ID" '{
  query: "query($live: SuiAddress!, $revoked: SuiAddress!) { live: object(address: $live) { asMoveObject { contents { type { repr } json display { output errors } } } } revoked: object(address: $revoked) { asMoveObject { contents { type { repr } json display { output errors } } } } }",
  variables: {live: $live, revoked: $revoked}
}')
curl -fsS "https://graphql.$NETWORK.sui.io/graphql" \
  -H 'Content-Type: application/json' --data "$QUERY" >"$RECORDS/claims.json"
jq -e '((.errors // []) | length) == 0 and .data != null' "$RECORDS/claims.json"
```

Indexing can lag transaction execution. Retry reads for a bounded period (for
example two minutes); do not issue another claim to fix delayed indexing.
Inspect both returned objects, not just HTTP success:

- Both are the expected attestation type with the approved subject and report data.
- The live claim has `revoked_at_ms: null`; the revoked claim has a timestamp.
- Both remain owned by the address derived from this Registry and subject.
  Inspect ownership using `sui client object`; derive the expected address using
  the SDK's `deriveObjectID(registry, '0x2::object::ID', BCS(subject))`, not a
  hand-written hash or the subject address itself.
- Display has no errors and renders the company name, description, report URL,
  digest (when supplied), and publication date as intended.

Stop and diagnose unexpected types, ownership, status, or Display errors before
claiming success. Treat report URLs as untrusted content when opening them.

## 5. Verify in Move Registry

Open <https://www.moveregistry.com> in a real browser. Do not assume the public
site runs the same release/configuration as a local checkout.

1. Select the intended package network. Open the auditor's MVR package page.
   Confirm package ID/version, README, source revision, and links. An auditor
   page is not evidence that a subject's audit is visible.
2. Open the auditor's Issued tab, if supported by that deployment. Find both
   example claim IDs, their subjects, and distinct live/revoked states. Issued
   visibility is not proof that the auditor is trusted in a subject's Security view.
3. Open the approved subject's package page/version and its Security view.
   Confirm the displayed auditor identity, claim wording, report link, and live
   state. Check how the revoked example is hidden or distinguished; it must not
   be presented as an active endorsement. The chain still retains it.
4. Record the actual page URL, network/version selection, and observed results
   or screenshot. If browser tools are absent, ask the user to perform these
   checks and supply evidence. Do not mark them passed without observation.

### Public visibility is a separate approval

The MVR consumer filters by configured trusted attester **package identity**, not
by whichever wallet signed or name the company registered. To request inclusion,
provide maintainers the network, original auditor package ID, verified source,
company/MVR name, desired label, core Registry configuration, and sample claim
IDs. Inclusion is the consumer operator's decision, not the onboarding agent's.

A missing Security card can mean unsupported deployment/network, absent trust
configuration, a subject/version mismatch, revocation, indexing lag, or rendering
failure. Diagnose those separately. Do not reissue repeatedly or silently edit
an allowlist. A local preview with explicit test configuration is useful but is
not proof of visibility on the public site.

### Maintainer-assisted consumer checks

Auditors do not need to build or modify the MVR frontend to issue claims. If
maintainers offer a local preview, use the intended release and network. Check
whether `NEXT_PUBLIC_ATTESTATION_CONFIG` is set: it replaces the **entire**
checked-in configuration, rather than merging entries. Preserve both networks
when constructing an override. Also check whether `NEXT_PUBLIC_LOCAL_*` endpoint
overrides redirect reads. Report presence/expected endpoints without dumping
unrelated environment values or secrets.

Have maintainers exercise the actual Security and Issued readers with the
verified claim IDs. Record whether the right core Registry, original auditor
identity, subject version, revocation states, and rendered Display were returned
without read errors. A passing query test is not a browser observation, and a
local preview is not a public deployment.

Report four results separately: chain state, metadata/name resolution, consumer
queries, and browser rendering. For example: “claims and name resolution
verified; consumer queries passed locally; public browser visibility pending
maintainer approval.” Mark checks not performed as pending, not passed. Mainnet
needs its own trust onboarding even after a successful testnet rehearsal.
