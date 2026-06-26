import { Transaction } from '@mysten/sui/transactions';
import { bcs } from '@mysten/sui/bcs';
import { deriveObjectID, normalizeSuiAddress } from '@mysten/sui/utils';

/** Mirror of the on-chain `attestation_registry::BoxKey { subject, revoked }`,
 *  the key a subject's two boxes are derived from. */
const BoxKey = bcs.struct('BoxKey', { subject: bcs.Address, revoked: bcs.bool() });

/**
 * Compute the address of a subject's *active* `Box` under the given `Registry`.
 * Mirrors `derived_object::derive_address(registry, BoxKey { subject, revoked:
 * false })` on-chain: the box is keyed by the `BoxKey` struct (defined in the
 * `attestation_registry` package — hence `registryPkg` is needed for the type
 * tag), with `revoked: false` selecting the active box. Revoked attestations
 * are moved to the sibling `revoked: true` address and never appear here.
 */
export function boxAddress(registryPkg: string, registryId: string, subject: string): string {
  const keyBytes = BoxKey.serialize({
    subject: normalizeSuiAddress(subject),
    revoked: false,
  }).toBytes();
  return deriveObjectID(registryId, `${registryPkg}::attestation_registry::BoxKey`, keyBytes);
}

/**
 * Append a `create_box(registry, subject)` move call to `tx`.
 */
export function createBoxTx(
  tx: Transaction,
  args: { attestationRegistryPkg: string; registryId: string; subject: string },
): void {
  tx.moveCall({
    target: `${args.attestationRegistryPkg}::attestation_registry::create_box`,
    arguments: [tx.object(args.registryId), tx.pure.id(args.subject)],
  });
}
