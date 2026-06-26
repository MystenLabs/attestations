// The attestation-registry client SDK: derive a subject's Box, read/list its
// attestations, and evaluate the Display-field conventions. Auditor-schema
// helpers live in ../examples/audit.ts; demo-only tooling in ../demo/.
export { boxAddress, createBoxTx } from './boxes.js';
export { listAttestations, getAttestation, type AttestationInfo } from './queries.js';
export { isEffective } from './conventions.js';
