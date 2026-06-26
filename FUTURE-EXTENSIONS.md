# Future Extensions

Design memos for surfaces we converged on during the PoC but deliberately
left out of the shipped module. Each section captures the design, why we
didn't include it, and what concrete use case would justify adding it.

## On-chain attestation inspection

The shipped registry has no public surface for reading an attestation's data
or status from Move code. The only public functions touching `Attestation<T>`
by value are `attest` (constructs) and `revoke` (consumes via
`transfer::receive`, flips `active`, transfers back). Accessors
(`subject`, `data`, `is_active`) exist but are unreachable from outside the
package because there's no public function that returns an
`Attestation<T>` or hands out a `&Attestation<T>`.

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
    cap: RevocationCap<T>,
    borrow: AttestationBorrow,
    ctx: &TxContext,
);
```

Hot potato has no abilities, so the borrow checker forces every code path to
discharge it via one of `put_back` / `revoke`. The hot potato carries
`(box_addr, attestation_id)` so `put_back` / `revoke` can verify the value
being discharged matches what was opened (with an `EBorrowMismatch` code).

Modeled on `sui::borrow::Referent` / `Borrow`. Bytecode-enforced, no
discipline note required.

### `read_data<T: copy>` alternative

When `T: copy`, a simpler one-call shape works:

```move
public fun data<T: store + copy>(
    box: &mut Box,
    rcv: Receiving<Attestation<T>>,
): T {
    let a = transfer::receive(&mut box.id, rcv);
    let d = *a.data();
    transfer::transfer(a, box.id.to_address());
    d
}
```

Returns the payload by copy; the function handles the
receive-then-transfer-back internally. Simpler API surface than the hot
potato; loses the ability to inspect `active`/`subject` in the same call
(would require additional functions or a snapshot struct).

### Why the choice between the two

- **Hot potato**: more general (works for `T: store`, no `copy` requirement),
  more bytecode-enforced invariants, more API surface.
- **`data` by copy**: simpler, restricted to `T: copy` schemas.

Pick the shape that matches the actual consumer. Both incur the same
`&mut Box` serialization cost because `transfer::receive` requires
`&mut UID` — concurrent on-chain reads against the same subject serialize
on the Box object regardless.

### Concrete use cases that would justify adding

1. **On-chain trust-list gating**: a downstream contract opens behavior only
   if the subject has an active attestation from a trusted attester. Reads
   `attester_of<T>()` and the attestation's `active` field.
2. **Compositional attestation**: schema C issues `Attestation<C>` if and
   only if `Attestation<A>` and `Attestation<B>` are both effective for the
   same subject. Reads two attestations during one Move call.
3. **Gating with payload check**: e.g., a contract opens behavior only if
   the audit score exceeds a threshold. Reads `data()` and compares.

For workloads that are high-throughput (many concurrent gating calls per
subject), the `&mut Box` serialization cost may push toward an alternative
storage model (DOF) — a tradeoff documented in the off-chain-vs-on-chain
discussion that drove the PoC's TTO choice.
