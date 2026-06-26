/**
 * Off-chain evaluator for the Display-field conventions documented in
 * CONVENTIONS.md at the repo root.
 *
 * Revocation is encoded by *which box* owns an attestation: `revoke` moves it
 * out of its subject's active box to a separate sink address. So any
 * attestation surfaced here — fetched from the active box — is, by
 * construction, not revoked. The only remaining effectiveness gate is
 * `expires_at`: an attestation is **effective** iff its `expires_at` Display
 * field (when present) is still in the future.
 */

import type { AttestationInfo } from './queries.js';

/**
 * Whether `attestation` (already known to be in its subject's active box) is
 * still effective. `now` defaults to `Date.now`; inject a fixed clock in tests.
 */
export function isEffective(
  attestation: AttestationInfo,
  now: () => number = Date.now,
): boolean {
  const expiresAt = readExpiresAt(attestation);
  return expiresAt === null || now() < expiresAt;
}

/**
 * The `expires_at` convention renders a timestamp. Schemas typically use the
 * `:ts` Display transform on a `u64` field, which produces an ISO 8601
 * string. Falls back to numeric parsing for schemas that surface the raw
 * milliseconds.
 */
function readExpiresAt(att: AttestationInfo): number | null {
  const raw = att.display?.['expires_at'];
  if (raw == null) return null;
  if (typeof raw === 'number') return raw;
  if (typeof raw === 'string') {
    const asNum = Number(raw);
    if (!Number.isNaN(asNum) && asNum > 0) return asNum;
    const asDate = Date.parse(raw);
    if (!Number.isNaN(asDate)) return asDate;
  }
  return null;
}
