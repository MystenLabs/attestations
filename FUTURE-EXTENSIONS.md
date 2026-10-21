# Future Extensions

Design memos for surfaces we converged on during the PoC but deliberately
left out of the shipped module. Each section captures the design, why we
didn't include it, and what concrete use case would justify adding it.

## On-chain attestation inspection

The shipped registry has no public surface for reading an attestation's data
or status from Move code. The only public functions touching `Attestation<T>`
by value are `attest` (constructs) and `revoke` (receives via
`transfer::receive`, sets `revoked_at_ms`, and transfers the attestation back to
the subject's address). Its accessors (`subject`, `data`, `created_at_ms`,
`revoked_at_ms`) are `#[test_only]`, and no public function returns an
`Attestation<T>` or hands out a `&Attestation<T>`. An attestation's status is
its `revoked_at_ms` field.

This is intentional. We don't have a concrete on-chain consumer (verifier
contract, compositional attestation, gating contract) in the PoC, so the
inspection API would ship as unused surface area. Tests take attestations
from the subject's address with `test_scenario` and read them through the
`#[test_only]` accessors, which aren't part of the production API.

When concrete consumers materialize, two patterns we worked through are
documented below.

### `AttestationBorrow` hot potato

Returns the attestation by value along with a non-droppable hot potato that
must be discharged by `put_back` or `revoke`:

```move
public struct AttestationBorrow {
    subject: ID,
    attestation_id: ID,
}

public fun borrow<T: store>(
    registry: &mut Registry,
    subject: ID,
    rcv: Receiving<Attestation<T>>,
): (Attestation<T>, AttestationBorrow);

public fun put_back<T: store>(
    registry: &mut Registry,
    attestation: Attestation<T>,
    borrow: AttestationBorrow,
);

public fun revoke<T: store>(
    registry: &mut Registry,
    attestation: Attestation<T>,
    _: Permit<T>,
    borrow: AttestationBorrow,
    clock: &Clock,
    ctx: &TxContext,
);
```

(A hypothetical future shape — gated by `Permit<T>` like the shipped `revoke`,
but taking the attestation by value after a `borrow`.)

Hot potato has no abilities, so the borrow checker forces every code path to
discharge it via one of `put_back` / `revoke`. The hot potato carries
`(subject, attestation_id)` so `put_back` / `revoke` can verify the value
being discharged matches what was opened (with an `EBorrowMismatch` code).

Modeled on `sui::borrow::Referent` / `Borrow`. Bytecode-enforced, no
discipline note required.

### A `T: copy` read-by-copy shape (deferred)

A simpler one-call `data<T: store + copy>(registry, subject, rcv): T` that
receives the attestation, copies its payload out, and transfers it back is
**deferred**.

The original objection — that a copyable payload would let anyone re-mint an
attestation from it, reissuing one after revocation or restamping its timestamp
— no longer holds. `attest` is gated by `Permit<T>`, and only `T`'s defining
module can mint a permit, so a third party holding a copy of `T` still cannot
issue an attestation carrying it. The `Attestation<T>` wrapper stays `key`-only
and non-copyable either way.

What remains is a narrower trade-off: `T: copy` would restrict the accessor to
copyable payloads, where the hot potato serves every `T: store`. It would be a
convenience overload rather than a replacement — worth adding if a schema wants
it.

### Immutable borrowing against TTO (a framework change, not a registry one)

Both shapes above pay the same cost: `transfer::receive` requires `&mut UID`, so
*reading* an attestation on-chain takes a **mutable** borrow of the `Registry`,
which holds every subject's anchor UID, and concurrent reads about any subjects
serialize on that object.

The more general fix is at the framework level rather than here: let a caller
obtain a `&T` from a `&Receiving<T>` given a `&UID` — borrowing against a
transferred-to object without receiving it. (Raised by @amnn in review of PR #1,
who noted it may be broadly worthwhile beyond this use case.)

That would be strictly better than either shape above. Reads would need only an
*immutable* borrow of the `Registry`, so the gating calls below wouldn't serialize
against each other; and the accessor here would collapse to a thin wrapper — no
hot potato, no discharge discipline, no `EBorrowMismatch`. It also largely
retires the throughput argument for switching storage models (see below), since
that argument exists only to escape the `&mut` borrow.

It is out of scope for this package: it changes Sui's transfer-to-object
primitive, not the registry. It's recorded here because if it lands, the borrow
machinery above is the wrong thing to build.

### Concrete use cases that would justify adding

1. **On-chain trust-list gating**: a downstream contract opens behavior only
   if the subject has a live attestation (one with no `revoked_at_ms`) from a
   trusted attester. Reads `type_name::original_id<T>()`.
2. **Compositional attestation**: schema C issues `Attestation<C>` if and
   only if `Attestation<A>` and `Attestation<B>` are both effective for the
   same subject. Reads two attestations during one Move call.
3. **Gating with payload check**: e.g., a contract opens behavior only if
   the audit score exceeds a threshold. Reads `data()` and compares.

For workloads that are high-throughput (many concurrent gating calls), the
`&mut Registry` serialization cost may push toward an alternative
storage model (DOF) — a tradeoff documented in the off-chain-vs-on-chain
discussion that drove the PoC's TTO choice. Immutable borrowing against TTO
(above) would remove the pressure entirely, and is the better answer if it
lands.
