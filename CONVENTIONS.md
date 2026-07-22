# Display Conventions

`attestations` keeps its core type minimal — `Attestation<T>` has a
`subject` and `data: T`. Cross-cutting behaviors that schemas might want (a
report's publication date, etc.) are expressed as **Display field conventions**
rather than additional Move types. Off-chain consumers (wallets, explorers, apps)
recognize these conventional field names and apply the corresponding semantics
when evaluating or presenting an attestation.

The benefit of conventions-over-functors is composability: a schema can adopt
zero, one, or many of these by including the corresponding fields in its
`register_display` call. Combining them doesn't require nested type wrappers
(`WithExpiry<Audit<OtterSec>>`) — the schema just lists the fields it surfaces,
and conventions stack naturally.

## Base effectiveness

Effectiveness is purely structural: an attestation is effective iff it lives in
its subject's *active* box. `revoke` moves it to the subject's *revoked* box, so
a consumer enumerating the active box only ever sees un-revoked attestations —
no field to read, no `active` flag. No *current* convention adds further
effectiveness conditions; the planned `expires_at` (see below) would.

## Presentation fields

These don't affect effectiveness; they're how an attestation renders. Most reuse
the **standard Sui Display field names**, so an `Attestation<T>` shows up
sensibly in any Display-aware tool (wallets, explorers), not just bespoke
consumers.

- **`name`** — short title (e.g. `b"Audit attestation"`).
- **`description`** — human-readable summary; may interpolate `data`
  (e.g. `b"Score: {data.score}/100"`).
- **`image_url`** — an image for the attestation: a grade badge, report
  thumbnail, etc. Either an `https` URL or an inline `data:image/svg+xml` URI
  (see *Inline SVG* below).
- **`link`** — a URL to the full artifact (the audit report, the CVE record).
- **`published_at`** — publication date of the attested artifact (e.g. an audit
  report), so consumers can show "published on …". Rendered from a `u64` ms field
  via Display V2's `:ts` transform (`{data.published_at_ms:ts}`). It's
  *attester-supplied*, so it can be backdated — a consumer needing a trustworthy
  "first seen" should use the attestation object's on-chain creation time instead.

```move
fields.push_back(b"link".to_string());
values.push_back(b"{data.report_url}".to_string());
```

**Inline SVG.** `image_url` may be a `data:image/svg+xml` URI rather than a
hosted image, which lets a schema render a badge derived from the attestation's
own data — a score, a pass/fail — with nothing to host and no link to rot.
Display V2's `:url` transform percent-encodes literals and fields in place, so
the SVG can live in the Display template itself:

```
data:image/svg+xml,{'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">':url}{data.score:url}{'</svg>':url}
```

For SVGs whose structure is computed on-chain rather than fixed in the template,
the `svg` and `codec` packages in [sui-potatoes/app] build one in Move and emit
it with `to_url()` (percent-encoded) or `to_data_uri()` (base64). None of this is
specific to attestations — it's the general Sui Display technique, and the
libraries already exist, so a schema should reuse them rather than hand-roll
encoding.

[sui-potatoes/app]: https://github.com/sui-potatoes/app

**Security note.** `image_url` and `link` are *attester-supplied content*, so:

- They must never be used to derive **identity** — which attester issued an
  attestation is established by `T`'s defining package (the bytecode-anchored
  attester), not by anything in these fields. A consumer rendering an attester
  badge must source it from its own trust config, never from `image_url`.
- A consumer should treat the URLs defensively: require `https` (or a
  `data:image/svg+xml` URI), and prefer constraining the host to the attester's
  known domains so one (whitelisted) attester can't render another's branding or
  point at unrelated hosts.
- An inline SVG is attester-supplied **active content**. Render it in an `<img>`,
  where scripts do not execute — *never* inline it into the DOM, where a
  `<script>` or an `onload` attribute inside the SVG would run with the
  consumer's origin. This is a sharper risk than a bad URL, because here the
  attester supplies the content itself, not just a pointer to it.

## Adding a new convention

A new convention is an additive change: define the field name, its rendered
type, the effectiveness rule (if any), and document it here. Existing schemas
continue to work; schemas adopting the new convention add the field to their
`register_display` call (or `add_display_field`, for an already-published
Display).

If a convention requires on-chain enforcement (e.g., a verifier contract that
needs `is_effective` to apply expiration without an off-chain hop), it should
graduate from this document into a typed Move helper. None of the conventions
here are at that point yet.

## Planned future conventions

Conventions we've specified but not yet shipped:

- **`expires_at`** — an *effectiveness* convention: an attestation is effective
  only while current time is before its `expires_at` Display field (absent =
  never expires), rendered from a `u64` ms field via `{data.expires_at_ms:ts}`.
  Unused so far — the audit schema doesn't expire — so it's parked here until a
  schema needs it. Off-chain check:
  `expiresAt !== null && Date.now() >= expiresAt`.
- **`polarity`** — distinguishes a *negative* attestation (a warning, e.g. a
  disclosed vulnerability) from a *positive* one (an endorsement, e.g. an audit),
  so consumers render and weigh the two differently. (negative-attestation
  fast-follow.)
- **`severity`** — for vulnerability disclosures, a CVSS-style severity band, so
  consumers can rank or threshold disclosures. (negative-attestation fast-follow.)
