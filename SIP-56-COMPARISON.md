# Replacing SIP-56

[SIP-56 ("Attestation registry")](https://github.com/sui-foundation/sips/pull/56)
is an in-progress Informational SIP by Sidestream Labs proposing an "open
standard for attesters to share signals about packages." Its [reference
implementation](https://github.com/sidestream-tech/sui-attestation-registry)
seeded much of the design conversation that led to this PoC, and the
[SIP-56 PR discussion](https://github.com/sui-foundation/sips/pull/56)
introduced primitives (derived addresses) that didn't exist in the original
proposal but that both designs now build on.

This document proposes that **this PoC's design should supersede SIP-56**
now that derived addresses ship as a stable platform feature. The remainder
explains where the two designs already agree (post-PR), where they still
diverge, and why each remaining divergence is an improvement.

## Historical context

SIP-56 was first published on 2025-02-17. The original specification stored
all attestations in a single central `Registry` package, distinguished
revocable vs. permanent attestations at the type level, and proposed an
explicit `attestation::register_type` step that froze a `Publisher` to
register each attestation type.

The PR discussion (March–August 2025) substantially reshaped the design.
Key threads:

- **Derived addresses** were proposed mid-discussion (April 2025) as a
  superior storage mechanism: attestations transferred to a per-package
  derived address can be fetched via `getOwnedObjects` and modified in
  place via "receive". This was a new platform feature at the time, not
  yet shipped, but the SIP-56 PR converged on building on top of it.
- **Revocation** was simplified from a per-type-revocable flag to a uniform
  bearer-`RevokeCap` pattern — any attestation is potentially revocable.
- **Pinning** was reframed from "package owner can hide attestations" to
  "package owner can highlight (pin) attestations they endorse."
- **Type registration** was nominally agreed to use a frozen
  `AttestationType<T>` wrapper around the type's `DisplayCap`, primarily
  to enforce Display immutability and provide on-chain type
  discoverability.
- **Authorization** moved from sender-keyed to a `*Cap` pattern.

This PoC was built on the storage primitive the PR converged on (derived
addresses). It diverges on revocation and authorization: rather than bake a
bearer cap into the core, the registry gates state changes with `Permit<T>`
and leaves revocation *policy* to the schema (see #8). The remaining
differences are in choices that *still* divide the two designs after the PR
discussion ended.

## What this PoC adopts from the PR-evolved SIP-56

- **Derived-address storage**. The `Registry` is a shared parent UID;
  per-subject `Box`es live at addresses derived from `(registry, subject)`.
  Attestations are owned by the Box via transfer-to-object. Off-chain
  consumers fetch all attestations about a subject from a single
  computable address.
- **Receive / re-transfer pattern** for state changes. Revocation in this
  PoC works this way: the registry receives the attestation from its active
  Box and transfers it to the subject's revoked sink (a sibling derived
  address).

These are the load-bearing improvements that came out of the SIP-56 PR
discussion, and both designs build on them.

## What this PoC changes from SIP-56

The remaining differences are improvements on the SIP-56 post-PR design.

### 1. Subject scope: any `ID`, not just packages

SIP-56 specifies `receiver: address` and constrains it to package
addresses. Several SIP-56 features (notably pinning, which requires the
receiver's `Publisher`) only make sense under that constraint.

This PoC uses `subject: ID` and works for any object: packages, addresses,
NFTs, transaction digests, anything that has an `ID`. The Move primitive
doesn't know or care what kind of thing is being attested about.

**Why this is an improvement**: trust signals are about objects generally,
not packages specifically. A reputation system might want to attest about
user addresses; a vulnerability database might want to attest about specific
package versions or transaction patterns. Narrowing `subject` to package
addresses bakes in an assumption that doesn't generalize, in exchange for
a feature (pinning) that this PoC argues belongs elsewhere anyway (see #5).

### 2. No type registration / no `AttestationType<T>`

SIP-56 post-PR has an explicit `register_type<T>` step that takes the
type's `DisplayCap`, wraps it in a frozen `AttestationType<T>` object, and
requires `&AttestationType<T>` to subsequently call `attest`. Two goals
were cited in the PR: (a) enforce Display immutability for the type, and
(b) make types self-discoverable on-chain.

This PoC has no registration step at all. Any Move type `T` can be used as
`Attestation<T>` data directly; `register_display<T>` is a separate
optional step gated by `Permit<T>`.

**Why this is an improvement**:
- *Display immutability* is achieved without a registration step by
  freezing a module-private `DisplayLock<T>` wrapper that holds the
  `DisplayCap`. This is the **same freeze-a-wrapper mechanism** SIP-56's
  PR-evolved design uses (amnn's `AttestationType<T>` proposal wraps
  `DisplayCap` and freezes it). The only difference is that SIP-56 also
  wires its frozen wrapper into authorization (passing
  `&AttestationType<T>` to `attest`), while this PoC's `DisplayLock<T>`
  has no further role after registration. The Display-immutability
  property is identical.
- *Type self-discoverability* is treated here as an off-chain concern.
  Indexers can enumerate `Attestation<T>` instances by struct-type filter
  (via `getOwnedObjects`); a wallet wanting "all known attestation types"
  builds that list from event streams. Putting type registration on-chain
  pays a real cost (parallelism bottleneck through the registry, ceremony
  for schema authors) for a feature that doesn't need to be on-chain to
  work.

### 3. Attester identity rooted in `T`'s package, not the signer's keypair

SIP-56's recorded attester is `created_by: address` = `tx.sender()` — the
keypair that signed the transaction.

This PoC's attester (emitted on the `Attested` event) is `T`'s defining
package address, resolved at mint time via `type_name::original_id<T>()`.

The mechanism: `attest<T>(registry, subject, data: T, ctx)` takes a `T`
value, and Move's construction rules restrict producing a `T` to `T`'s
defining module. So the existence of an `Attestation<T>` on-chain is
**bytecode proof** that `T`'s defining package's code path was taken to
mint it. No separate permit or capability is needed; the type system
already enforces this.

**Why this is an improvement**: for a trust-signal primitive, "this came
from the protocol that defined the type" is a stronger and more useful
guarantee than "this address signed the tx." Under SIP-56's design, a
third party calling a schema's permissive wrapper looks identical on-chain
to the schema package's own code path; the `created_by` field tells you
which keypair signed, not which protocol vouches.

**Schemas can still opt into permissionless attestation** — they just
express it explicitly in the schema's data type. The pattern is to
include a `sender: address` (or similarly named) field in `T` and have
the schema's constructor populate it from `ctx.sender()`:

```move
public struct UserAudit has store, drop {
    score: u8,
    sender: address,
}

public fun attest_user_audit(
    registry: &Registry, subject: ID, score: u8, ctx: &mut TxContext,
): ID {
    attestation_registry::attest<UserAudit>(
        registry,
        subject,
        UserAudit { score, sender: ctx.sender() },
        ctx,
    )
}
```

Now anyone can call `attest_user_audit`. The recorded attester (at the
type level, available to indexer queries) is still the schema package
("this is a UserAudit attestation"), but the per-attestation signer is
captured in the data ("by *this* address"). Off-chain consumers see both
pieces and can weight them as they like. This is a strictly more
expressive choice than SIP-56's universal `created_by` — the schema
author decides whether per-attestation signer identity is part of the
trust signal.

**Side benefit: trust grouping through package upgrades.** Because the
recorded attester resolves to `T`'s defining package's *original*
publish address (via `type_name::original_id<T>()`), all attestation
types defined by the same package share an on-chain identity that's
stable across upgrades. An auditor that publishes an `Audit` type and
later upgrades the package to add `LightAudit`, `SourceVerification`,
etc., has those new types automatically classified under the same
attester. Consumer trust lists key by package address — a list of
"trusted auditors" works at the granularity of "this package's
attestations," and any new attestation types the auditor introduces
ride along under the same trust grouping.

This composes correctly at the security level: upgrade authority *is*
attestation-dynamics authority. If you've trusted the auditor's
existing attestations, you've already implicitly trusted that they
could change the rules via upgrade — so trusting their new types
automatically is the consistent position rather than an oversight.

SIP-56's per-attestation `created_by` doesn't compose this way: each
attestation's identity is the signer keypair, with no on-chain
grouping primitive that survives upgrades or even spans multiple
attestation types from the same author.

### 4. No pinning — curation is a consumer concern

SIP-56 has pin/unpin operations callable by the receiver's package
publisher to highlight attestations the publisher wants explorers to
surface.

This PoC has no pinning. Curation — deciding which attestations matter,
which attesters to trust, which to surface prominently — lives entirely
off-chain and on the *consumer* side.

**Why this is an improvement**: the design question for pinning is "who
gets to shape which trust signals consumers see?" SIP-56 answers "the
package owner." This PoC argues that's the wrong principal:

- Package authors have a direct conflict of interest with consumers when
  it comes to surfacing trust signals. The whole point of third-party
  attestations (audits, vulnerability disclosures) is that they aren't
  filtered by the subject. Letting the subject highlight or downplay
  attestations defeats the trust primitive.
- The amnn-proposed shift from "hide" to "highlight" in the PR
  acknowledges this conflict but doesn't resolve it: a malicious package
  author can still pin a self-issued attestation to drown out a
  legitimate critical one. The signal is still being shaped by the wrong
  party.
- The actually-correct curators are *consumers* (wallets, explorers, end
  users) and the *attester ecosystem* (curated trust lists of reputable
  attesters). Both live off-chain naturally and don't need a Move-level
  primitive to express.

This is the most opinionated of the remaining differences. Consumers
implement their own curation by maintaining off-chain trust lists of the
attesters they consider authoritative.

### 5. Storage: per-subject `Box` (derived child), not central registry

Both designs use derived addresses (post-PR). The remaining difference is
the layer of indirection: SIP-56's storage is "attestations transferred
directly to the derived address," while this PoC introduces an explicit
`Box` shared object that *lives* at the derived address and owns the
attestations.

**Why the Box layer is useful**: the Box exists for two reasons.

- **Bytecode-verifiable subject identity**: the Box's `subject: ID` field
  records what the Box is about. Without it, the derived-address scheme
  alone doesn't anchor the relationship on-chain — a viewer would have
  to know the (registry, subject) pair to interpret an address as "a
  bag of attestations about subject S." The Box surfaces it directly.
- **Receive/modify primitive**: `transfer::receive(&mut box.id, rcv)`
  requires a `&mut UID` for the parent. Without an actual object at the
  derived address, there's no UID to borrow. The Box gives us the
  per-subject UID needed for revoke (and any future state-change
  operation).

The Box is created explicitly (`create_box(registry, subject)`) before
the first attest for a subject. This adds a one-time setup cost per
subject in exchange for the two properties above.

### 6. Event shape: phantom `T` + `subject` only

SIP-56 events (implicit; the SIP doesn't fully specify) would carry the
attestation id, type info as a string, attester address, and so on.

This PoC emits `Attested<phantom T> { subject: ID }` and
`Revoked<phantom T> { subject: ID }`. The phantom `T` makes the event's
fully-qualified Move type the filterable surface — RPC subscribers filter
by `eventType: "...Attested<...Audit<...>>"` directly. Other facts
(`attester`, `attestation_id`, `revoker`) are recoverable from tx
effects or from the object's content.

**Why this is an improvement**: the phantom-T pattern is strictly more
RPC-filterable than a `type_name: String` field (which requires parsing).
Other fields are denormalization — they appear in tx effects or in the
attestation's own state, so duplicating them in the event is a
maintenance hazard (two sources of truth) without information gain.

### 7. Revocation status by box membership, and event-recorded revoker

SIP-56's attestation struct has `revoked_by: Option<address>` —
`None` means active, `Some(addr)` records who revoked.

This PoC stores no status on the struct at all: revocation is encoded by
*which* box owns the attestation (live in the active box, revoked in the
sink), and revoker identity goes in the `Revoked` event.

**Why this is an improvement**: the revoker is in the tx context already
(`tx.sender()` of the revoke tx); the event carries it explicitly for
indexer convenience. Storing it on the struct is denormalization with the
same "two sources of truth" hazard as the event-field case. And encoding
revoked-vs-live as box membership means the common read — "all the live
attestations about S" — is a single `getOwnedObjects` on the active box
with no per-object status field to filter on.

### 8. Revocation policy lives in the schema, not the core

SIP-56 (post-PR) bakes a universal bearer `RevokeCap` into the registry.
This PoC keeps the core policy-free: `revoke<T>(box, _: Permit<T>, rcv)` is
gated only by `Permit<T>` — which only `T`'s defining module can mint — and
performs a uniform move (out of the active box, into the revoked sink) plus
a `Revoked<T>` event. It mints no cap. `attest<T>` returns the new
attestation's `ID`, the
one fact a schema can't otherwise recover, so the schema can build whatever
revocation authority it wants: a bearer cap bound to that id, an admin cap,
a multisig, or none.

**Why this is an improvement**: the registry shouldn't dictate revocation
policy — the party that defines what an attestation *means* (the schema
package) should. This is the same `Permit<T>` split already used for
`register_display`: the core owns the mechanism, the schema owns the policy.
Permanent commitments are expressed by a schema simply not exposing a revoke
path — no "transfer the cap to `@0x0`" anti-pattern needed.

## What we gained

- **Bytecode-verifiable attester identity** via `Permit<T>` gating.
- **Policy-free core revocation**: schemas pick their own revocation
  authority (bearer cap, admin, multisig, or immutable) via `Permit<T>`.
- **Type-filtered native RPC enumeration** for the dominant access
  pattern ("all attestations about subject S") and for cross-subject
  type filters ("all Audit attestations" globally).
- **Smaller core surface**: no `register_type`, no `AttestationType<T>`,
  no `pinned_by`/`unpinned_by` fields, no string-encoded type info on
  events, no on-chain pin/unpin.
- **General `subject: ID`**: works for trust signals about any object,
  not just packages.

## What we deliberately don't have

- **On-chain "official" type registry**: type discoverability is
  off-chain via event-stream enumeration.
- **Publisher-anchored pinning**: curation is consumer-side.
- **Permissionless attest at the registry layer**: schemas that want
  third-party attesters wrap and gate.

## Summary of the SIP-56 PR discussion threads

For readers coming from the SIP-56 PR, the relevant threads and how each
plays out in this PoC:

| Thread (SIP-56 PR) | Resolution in PR | Status in this PoC |
|---|---|---|
| Curated vs. discoverable types | Stayed with curated + on-chain `AttestationType<T>` | Removed; type discoverability off-chain |
| Scope: minimum viable attestations | Broad agreement on minimal scope | Adopted |
| Revocation (per-type vs. universal) | Universal via `RevokeCap` | Diverged: policy-free core gated by `Permit<T>`; revocation policy lives in the schema |
| Pinning: hide vs. highlight | Switched to highlight | Removed entirely (consumer concern) |
| Modifying attestations | Receive-modify-retransfer via derived addresses | Adopted as receive-and-retransfer: `revoke` moves the attestation between derived addresses, no in-place mutation |
| Authorization scheme | Sender → `*Cap` pattern | Diverged: `Permit<T>` gating (schema chooses cap / admin / multisig) |
| Display immutability | Frozen `AttestationType<T>` wraps `DisplayCap` | Same freeze-a-wrapper mechanism (`DisplayLock<T>`) |
| Self-discoverable types | Frontends fetch list via on-chain `AttestationType<T>` | Off-chain via event subscription |
| Derived addresses timeline | Acknowledged as months out; PoC initially worked around it | This PoC is built directly on them |

## Open questions for SIP-56's audience

If the SIP-56 audience disagrees with this PoC on a specific item, the
typical mitigation:

- **"We need on-chain type discoverability"**: a schema-package convention
  (or a thin separate package) can mint frozen `AttestationType<T>`
  marker objects at first-attest time, leaving the core registry
  unchanged. This is additive and doesn't require the registry to know
  about types.
- **"We need pinning for explorer UX"**: a separate "trust list" package
  per consumer surface (wallet, explorer) can express which attestations
  to surface, keyed on whatever criteria that consumer wants — without
  involving the package author.
- **"We need permissionless attest"**: schema packages express this in
  the schema by exposing a public constructor and (typically) embedding
  `sender: address` in the data. See Section 3 above for the pattern.
  The registry's bytecode guarantee remains "this came from the schema
  package's code path"; the schema decides whether per-attestation
  signer identity is part of the recorded data.

The point of the divergences isn't that SIP-56's positions are wrong, but
that the alternatives are expressible at higher layers and don't need to
live in the registry primitive. Keeping the primitive minimal makes it
easier to compose those higher layers without paying for them when they
aren't wanted.
