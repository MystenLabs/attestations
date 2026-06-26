# Display Conventions

`attestation_registry` keeps its core type minimal — `Attestation<T>` has a
`subject` and `data: T`. Cross-cutting behaviors that schemas might want
(expiration, etc.) are expressed as **Display field conventions** rather than
additional Move types. Off-chain consumers (wallets, indexers, the `ts/`
library) recognize these conventional field names and apply the corresponding
semantics when evaluating trust.

The benefit of conventions-over-functors is composability: a schema can adopt
zero, one, or many of these by including the corresponding fields in its
`register_display` call. Combining them doesn't require nested type wrappers
(`WithExpiry<WithRequires<Audit<OtterSec>>>`) — the schema just lists the
fields it surfaces, and conventions stack naturally.

## Base effectiveness

Revocation is **not** a convention — it's structural. An attestation lives in
its subject's *active* box; `revoke` moves it out to a separate revoked-sink
address. So a consumer that enumerates a subject's active box only ever sees
un-revoked attestations — revocation needs no field to read, and there is no
`active` flag to consult. The conventions below add *further* effectiveness
conditions (e.g. expiry) on top of attestations already known to be active.

## Conventions

### `expires_at`

An attestation is **effective** only when current time is before the value of
its `expires_at` Display field. Absence of the field means the attestation
never expires.

The field's rendered type is a timestamp. Recommended template form using
Display V2's `:ts` transform on a `u64` field:

```move
fields.push_back(b"expires_at".to_string());
values.push_back(b"{data.expires_at_ms:ts}".to_string());
```

This requires the schema's `T` to include an `expires_at_ms: u64` field. The
schema decides how that field is populated (always-present, sentinel for
"never expires," etc.).

Off-chain evaluator pseudocode:

```ts
const expiresAt = parseTimestamp(attestation.display?.expires_at);
const expired = expiresAt !== null && Date.now() >= expiresAt;
```

### `polarity`

Distinguishes **positive** attestations (an assertion of good standing — e.g.
an audit) from **negative** ones (an assertion of a problem — e.g. a
vulnerability disclosure). The field renders the literal string `positive` or
`negative`; absence defaults to `positive`.

```move
fields.push_back(b"polarity".to_string());
values.push_back(b"positive".to_string()); // or b"negative"
```

Polarity is a fixed property of the schema, so the template hardcodes it
rather than reading `data`.

Consumers use it to render the two kinds differently and — for negatives — to
**propagate**: a negative attestation that is effective on a package is
surfaced on that package's *dependents* (transitively, via the dependency
graph), so a vulnerability in a dependency shows up when browsing anything
that depends on it. Propagation is implicit and graph-derived, pushing a
dependency's problems toward its dependents; a revoked or expired negative
attestation does not propagate.

### `severity`

A severity score for negative attestations, reusing **CVSS** (the Common
Vulnerability Scoring System): a base score from `0.0` to `10.0`. Consumers
sort negatives by it (most severe first) and map it to the standard CVSS v3.1
qualitative bands for display:

| Band | Score |
|------|-------|
| None | 0.0 |
| Low | 0.1–3.9 |
| Medium | 4.0–6.9 |
| High | 7.0–8.9 |
| Critical | 9.0–10.0 |

```move
fields.push_back(b"severity".to_string());
values.push_back(b"{data.severity}".to_string());
```

The field renders the raw number so it is machine-sortable; the consumer
formats it (e.g. `7 · High`). A schema using integer scores (`0`–`10`) is a
valid subset. Absence means unscored.

## Presentation fields

These don't affect effectiveness; they're how an attestation renders. They
reuse the **standard Sui Display field names**, so an `Attestation<T>` shows up
sensibly in any Display-aware tool (wallets, explorers), not just bespoke
consumers.

- **`name`** — short title (e.g. `b"Audit attestation"`).
- **`description`** — human-readable summary; may interpolate `data`
  (e.g. `b"Score: {data.score}/100"`).
- **`image_url`** — an image for the attestation: a grade badge, report
  thumbnail, etc.
- **`link`** — a URL to the full artifact (the audit report, the CVE record).

```move
fields.push_back(b"link".to_string());
values.push_back(b"{data.report_url}".to_string());
```

**Security note.** `image_url` and `link` are *attester-supplied content*, so:

- They must never be used to derive **identity** — which attester issued an
  attestation is established by `T`'s defining package (the bytecode-anchored
  attester), not by anything in these fields. A consumer rendering an attester
  badge must source it from its own trust config, never from `image_url`.
- A consumer should treat the URLs defensively: require `https`, and prefer
  constraining the host to the attester's known domains so one (whitelisted)
  attester can't render another's branding or point at unrelated hosts.

## Adding a new convention

A new convention is an additive change: define the field name, its rendered
type, the effectiveness rule, and document it here. Existing schemas continue
to work; schemas adopting the new convention add the field to their
`register_display` call.

If a convention requires on-chain enforcement (e.g., a verifier contract that
needs `is_effective` to apply expiration without an off-chain hop), it should
graduate from this document into a typed Move helper. None of the conventions
above are at that point yet.
