# Future Extensions

Design memos for surfaces we converged on during the PoC but deliberately
left out of the shipped module. Each section captures the design, why we
didn't include it, and what concrete use case would justify adding it.

## On-chain attestation inspection

The shipped registry has no public surface for reading an attestation's data
or status from Move code. The only public functions touching `Attestation<T>`
by value are `attest` (constructs) and `revoke` (receives via
`transfer::receive` and moves the attestation to the subject's revoked box).
Accessors (`subject`, `data`) exist but are unreachable from outside the package
because no public function returns an `Attestation<T>` or hands out a
`&Attestation<T>`. An attestation's status is which box owns it, not a field on
the attestation.

This is intentional. We don't have a concrete on-chain consumer (verifier
contract, compositional attestation, gating contract) in the PoC, so the
inspection API would ship as unused surface area. Test-only seams
(`borrow_for_testing` / `put_back_for_testing`) exist for tests; they're
gated behind `#[test_only]` and aren't part of the production API.

When concrete consumers materialize, two patterns we worked through are
documented below.

### `AttestationBorrow` hot potato

Returns the attestation by value along with a non-droppable hot potato that
must be discharged by `put_back` or `revoke`:

```move
public struct AttestationBorrow {
    box_addr: address,
    attestation_id: ID,
}

public fun borrow<T: store>(
    box: &mut Box,
    rcv: Receiving<Attestation<T>>,
): (Attestation<T>, AttestationBorrow);

public fun put_back<T: store>(
    box: &mut Box,
    attestation: Attestation<T>,
    borrow: AttestationBorrow,
);

public fun revoke<T: store>(
    box: &mut Box,
    attestation: Attestation<T>,
    _: Permit<T>,
    borrow: AttestationBorrow,
    ctx: &TxContext,
);
```

(A hypothetical future shape — gated by `Permit<T>` like the shipped `revoke`,
but taking the attestation by value after a `borrow`.)

Hot potato has no abilities, so the borrow checker forces every code path to
discharge it via one of `put_back` / `revoke`. The hot potato carries
`(box_addr, attestation_id)` so `put_back` / `revoke` can verify the value
being discharged matches what was opened (with an `EBorrowMismatch` code).

Modeled on `sui::borrow::Referent` / `Borrow`. Bytecode-enforced, no
discipline note required.

### Why not a `T: copy` read-by-copy shape

A simpler one-call `data<T: store + copy>(box, rcv): T` that receives the
attestation, copies its payload out, and transfers it back was considered and
**rejected** — not merely deferred. Requiring `T: copy` would let anyone who can
reach an attestation copy its payload out and re-mint it: reissue an attestation
after it was revoked, or mint one with a different timestamp — defeating the
uniqueness and permanence the `key`-only design guarantees. The hot-potato
pattern keeps the attestation a single, non-copyable object throughout, so it is
the only viable inspection shape.

The hot potato incurs a `&mut Box` serialization cost because
`transfer::receive` requires `&mut UID` — concurrent on-chain reads against the
same subject serialize on the Box object regardless.

### Concrete use cases that would justify adding

1. **On-chain trust-list gating**: a downstream contract opens behavior only
   if the subject has a live attestation (one in its active box) from a trusted
   attester. Reads `attester_of<T>()`.
2. **Compositional attestation**: schema C issues `Attestation<C>` if and
   only if `Attestation<A>` and `Attestation<B>` are both effective for the
   same subject. Reads two attestations during one Move call.
3. **Gating with payload check**: e.g., a contract opens behavior only if
   the audit score exceeds a threshold. Reads `data()` and compares.

For workloads that are high-throughput (many concurrent gating calls per
subject), the `&mut Box` serialization cost may push toward an alternative
storage model (DOF) — a tradeoff documented in the off-chain-vs-on-chain
discussion that drove the PoC's TTO choice.
