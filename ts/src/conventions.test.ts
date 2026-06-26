import test from 'node:test';
import assert from 'node:assert/strict';

import { isEffective } from './conventions.js';
import type { AttestationInfo } from './queries.js';

/** Build a minimal AttestationInfo with just the fields the evaluator reads. */
function att(display: Record<string, unknown>): AttestationInfo {
  return { id: '0x1', version: '1', digest: 'd', type: 'Attestation<T>', display };
}

// Fixed clock: now = 1000ms past the epoch (1970-01-01T00:00:01.000Z).
const now = () => 1000;

test('no expiry is effective', () => {
  assert.equal(isEffective(att({}), now), true);
});

test('future expiry is effective', () => {
  assert.equal(isEffective(att({ expires_at: '1500' }), now), true);
});

test('past expiry is ineffective', () => {
  assert.equal(isEffective(att({ expires_at: '500' }), now), false);
});

test('ISO-8601 expiry is parsed', () => {
  assert.equal(isEffective(att({ expires_at: '1970-01-01T00:00:00.500Z' }), now), false);
  assert.equal(isEffective(att({ expires_at: '1970-01-01T00:00:02.000Z' }), now), true);
});
