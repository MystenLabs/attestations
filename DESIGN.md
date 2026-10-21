# Design and Rationale

This document records *why* the on-chain design is shaped the way it is. For
*how to use it* see `README.md`; for deferred ideas `FUTURE-EXTENSIONS.md`; for
the SIP-56 comparison `SIP-56-COMPARISON.md`; for schema-level Display
conventions `CONVENTIONS.md`.

## Core model

The whole design follows from four choices:

- **Off-chain primary.** The dominant access pattern is off-chain consumers
  (wallets, explorers, apps like the mvr frontend) reading attestations about
  a subject.
  Every on-chain choice was weighed against "does this make the off-chain read
  better, the same, or worse?"
- **Attester = `T`'s defining package.** The attester recorded for an
  `Attestation<T>` is `type_name::original_id<T>()` — the original publish
  address of `T`'s defining package, not the signer. This is
  bytecode-verifiable: `attest` is gated by `Permit<T>`, which only `T`'s
  defining module can mint — so an `Attestation<T>` can only exist because `T`'s
  package authorized it.
- **Permanent, `key`-only attestations.** `Attestation<T>` has `key` only, and
  no public function returns one by value, so external callers can't transfer,
  wrap, or drop it. Once created it cannot be destroyed; its only dispositions
  are `attest` and `revoke` (see "Lifecycle invariant").
- **Status is a field on the attestation.** Each subject has one derived
  address, which owns every attestation about it. `revoke` sets the
  attestation's `revoked_at_ms` and returns it to that address, so enumerating
  the address yields live and revoked attestations alike, and a consumer reads
  `revoked_at_ms` to tell them apart.

Everything cross-cutting — revocation *policy*, expiration, dependency
relationships — is pushed out of the core: revocation authority to the schema
(via `Permit<T>`), the rest to Display-field conventions evaluated off-chain.

## Storage: one derived address per subject, transfer-to-object

```
Registry (shared singleton)
  ├── anchors: Table<ID, UID>           → each subject's anchor UID, claimed by its first revoke
  └── derive_address(registry, subject) → owns every Attestation<T> about subject (TTO)
```

- **`Registry`** is a `key`-only shared singleton, created in `init`; every subject's address is derived from its UID, and its `anchors` table holds the UIDs that `revoke` receives with. `attest` takes it by read-only reference, and `revoke` by mutable reference (see "Revocation" below).
- **The subject's address** is
  `derived_object::derive_address(registry, subject)`, keyed by the subject's
  `ID` — *computable off-chain* from `(registry_id, subject_id)`. The key type
  is `0x2::object::ID`, so the derivation needs no type from this package.
  Consumers read a subject's attestations from that address via
  `getOwnedObjects(addr, filter={StructType: ...})`, with native server-side
  type filtering.
- **`Attestation<T: store>`** is transferred to the subject's address by
  `attest`, which needs no object there; `revoke` receives it from that address
  and transfers it back.

`revoke` needs a `&mut UID` at the subject's address for `transfer::receive`.
The first `revoke` for a subject claims that UID with `derived_object::claim`
and stores it in `Registry.anchors`, keyed by the subject; later revokes borrow
it from there. No object exists at the address, and no setup transaction comes
before a subject's first revoke. The cost is that `revoke` takes
`&mut Registry`, so all revocations are sequenced through the one shared
object.

Earlier iterations encoded status as an on-chain `enum Status`, then as an
`active: bool` flag, then as which of two derived addresses owned the
attestation: an *active* address with a claimed `Box` object, or a *revoked*
address. Box membership let a consumer list only live attestations, with no
per-object filter. The current design stores the status on the attestation, as
`revoked_at_ms`, so a consumer filters per object.

### Why TTO, not DOF

DOF was built and rejected (reference snapshot: `mdgeorge/box-dof-reference`).
Listing "all `Attestation<Audit>` on subject S" under DOF needs a client-side
filter over all of S's dynamic fields, because DOF queries have no server-side
type filter; TTO's `getOwnedObjects` does. The cost is that on-chain TTO reads
need the subject's anchor UID by `&mut` (`transfer::receive` needs `&mut UID`),
which here means `&mut Registry`, where DOF reads need only `&` of the parent;
we accept it because the read story dominates. On-chain inspection patterns we
deferred are in `FUTURE-EXTENSIONS.md`.

## Attestation lifecycle invariant

```move
public struct Attestation<T: store> has key {
    id: UID,
    data: T,
    subject: ID,
    created_at_ms: u64,
    revoked_at_ms: Option<u64>,
}
```

Once created, an Attestation is never destroyed, and it is always owned by its `subject`'s address. `attest` creates it there and sets `created_at_ms` from the `Clock`; `revoke` sets `revoked_at_ms` from the `Clock` and transfers it back to the same address. `revoke` aborts with `EAlreadyRevoked` on an attestation whose `revoked_at_ms` is already set, so the field is set at most once.

## Attester identity: trust and gating

Because the attester is `T`'s defining package rather than the signer:

- Trust lists are keyed by package address — "I trust this auditor" means "I
  trust attestations from this package."
- New attestation types added in package upgrades inherit the same attester
  identity. Upgrade authority is attestation-dynamics authority anyway, so this
  composes.
- Permissionless attestation is a schema-level opt-in: the schema exposes a
  public constructor and (typically) puts `sender: address` in its data. The
  type-level attester is still the schema package; the per-attestation signer
  lives in the data.

`attest`, `register_display`, and `revoke` are **uniformly gated by
`Permit<T>`**, which only `T`'s defining module can mint. The permit — not the
mere ability to construct a `T` — is the authority, so the model holds even
where a schema exposes a public constructor for `T` (permissionless schemas do,
on purpose): such a schema exposes a public `attest` *wrapper* that mints the
permit, not a bare path to forge `Attestation<T>` from a stray `T` value.

## Revocation: `Permit<T>`-gated, policy in the schema

```move
public fun attest<T: store>(registry: &Registry, _: Permit<T>, subject: ID, data: T, clock: &Clock, ctx)
public fun revoke<T: store>(registry: &mut Registry, _: Permit<T>, subject: ID, rcv: Receiving<Attestation<T>>, clock: &Clock, ctx)
```

`attest` transfers the attestation to `subject`'s address (derived from the
registry id) and returns nothing, so a schema can't learn the new attestation's
`ID` in the same call. It takes `&Registry` and derives the address from that
object's id. Only `init` constructs the registry, so a caller cannot substitute
an arbitrary id and send an attestation to an address that this registry's
`revoke` cannot receive from. The read-only borrow adds a shared-object input,
but concurrent attestations do not mutate the registry or serialize against
each other merely by reading it. We accept shared-object version scheduling to
avoid a separate frozen reference object and its client configuration.
`revoke` takes `&mut Registry`, so revocations are sequenced with each other
and with the attestations that read the registry.

`attest` needs no object at the subject's address. `revoke` claims the
subject's anchor UID on the subject's first revoke, receives the attestation
with it, sets `revoked_at_ms`, transfers the attestation back to the same
address, and emits `Revoked<T>`.

The update and event stay uniform here; the *authority* does not. Because `revoke`
is gated by `Permit<T>` (see "Attester identity: trust and gating"), the base
prescribes no revocation policy — each schema gates its own `revoke_*` wrapper
(bearer cap, admin cap, multisig, …) and then mints the permit. Every policy is
reconstructable schema-side (see "Schema-level patterns"), with one limit: a
per-attestation bearer cap needs the attestation's `ID` when the cap is minted,
and `attest` does not return it.

Revocation is **terminal in the current bytecode** — no function clears
`revoked_at_ms`, and `revoke` aborts with `EAlreadyRevoked` on a revoked
attestation — but not cryptographically permanent: a future upgrade could add a
function that clears `revoked_at_ms`. The property given up is
bytecode-provable irrevocability; a schema is permanent only by exposing no
revoke path. That's weaker than burning a cap, but upgrade authority is already
attestation-dynamics authority.

## Display registration: parked cap, append-only Display

`register_display<T>(...)` creates `Display<Attestation<T>>`, applies the
schema's fields, shares it, and transfers the `DisplayCap` to the Registry's
address (TTO). The cap is *kept*, not destroyed: `add_display_field<T>` lets the
schema (gated by `Permit<T>`) receive it, append fields, and re-park it. Adding
is allowed; altering or removing an existing field is not — `add_display_field`
aborts on a field name that's already set, and no other public path exposes the
cap's `set`-overwrite / `unset` / `clear`. So the Display is effectively
**append-only**: a schema can grow its template over time but can't rewrite it.

## Events: phantom T, minimal payload

```move
public struct Attested<phantom T> has copy, drop { subject: ID }
public struct Revoked<phantom T> has copy, drop { subject: ID }
```

- `phantom T` makes the event's fully-qualified Move type the filterable
  surface: subscribers filter by
  `eventType: "0xPKG::attestations::Attested<0xAUD::audit::Audit>"`
  directly, with no string parsing.
- `subject` is the only field; everything else is recoverable from `tx.effects`
  or the attestation object. Denormalizing (attester, id, revoker) onto events
  creates two-sources-of-truth hazards without saving indexers any query work.

## Display-mixin conventions

Cross-cutting behaviors like expiration (`expires_at`) are Display field
conventions, evaluated off-chain by any consumer that adopts them (e.g. the mvr
frontend; see `CONVENTIONS.md`). They don't need on-chain enforcement
(off-chain primary), and modeling them as Move wrappers created composability
problems — `WithExpiry<Audit<OtterSec>>` is awkward to nest, and wrappers
confused the attester-resolution rule. Display fields stack naturally: a schema
just includes the relevant fields in its `register_display` call.

## Schema-level patterns

The base is minimal; schemas express their semantics in their own package, not
via registry flags:

- **Revocation policy**: a schema gates its `revoke_*` wrapper before minting
  `Permit<T>`. `auditor` uses one `AuditAdminCap` — a single authority over all
  of an auditor's attestation types, including any added in later upgrades; the
  other extreme — a per-attestation bearer cap (`VulnRevokeCap` with a
  `receiving_object_id` guard) — is the planned `vuln_example` fast-follow. It
  needs the attestation's `ID` when the cap is minted, which `attest` does not
  return. No `revoke_*` wrapper = permanent.
- **Permissioned vs permissionless**: a private data constructor is
  permissioned (only the schema package attests); a public constructor plus a
  `sender: address` field is permissionless with the signer captured in the
  data.
- **Expiration**: opt into the `expires_at` Display convention by including its
  template entry in `register_display`; consumers apply the semantics.

## What this design deliberately doesn't have

- **On-chain type registry** (SIP-56's `register_type`). Type discoverability is
  off-chain — enumerate events, filter by struct-type via RPC.
- **Pinning by package publisher.** Curation of trust signals is a consumer
  concern; package authors are the wrong principal. See `SIP-56-COMPARISON.md`.
- **On-chain inspection of attestation data** as a public API. The
  `borrow`/`put_back` hot-potato pattern is deferred to `FUTURE-EXTENSIONS.md`
  until a concrete consumer appears.
- **A built-in revocation policy.** The base gates `revoke` on `Permit<T>` and
  leaves the authority model to the schema; in particular, no sender-keyed
  authorization in the base.
- **`store` on `Attestation<T>`.** It's `key`-only; external callers can't wrap,
  transfer, or drop it.

## Related documents

- `README.md` — quickstart, repo layout, running the demo.
- `CONVENTIONS.md` — schema-level Display conventions and their semantics.
- `FUTURE-EXTENSIONS.md` — design memos for deferred surfaces (on-chain
  inspection).
- `SIP-56-COMPARISON.md` — point-by-point comparison with SIP-56.
