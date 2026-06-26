import { Transaction } from '@mysten/sui/transactions';

/**
 * Append `audit_example::audit::attest_audit(registry, subject, score,
 * report_url)` to `tx`. Audits are revoked via the auditor's `AuditAdminCap`
 * (see `revokeAuditTx`), not a per-attestation cap, so this returns nothing.
 */
export function attestAuditTx(
  tx: Transaction,
  args: {
    auditExamplePkg: string;
    registryId: string;
    subject: string;
    score: number;
    reportUrl: string;
  },
): void {
  tx.moveCall({
    target: `${args.auditExamplePkg}::audit::attest_audit`,
    arguments: [
      tx.object(args.registryId),
      tx.pure.id(args.subject),
      tx.pure.u8(args.score),
      tx.pure.string(args.reportUrl),
    ],
  });
}

/**
 * Append `audit_example::audit_v2::attest_audit_v2(registry, subject, score,
 * report_url)` to `tx`.
 *
 * `auditExamplePkg` must be the *upgraded* (v2) package id, since that is
 * where the `audit_v2` module is defined. Returns nothing (revoked via the
 * shared `AuditAdminCap`).
 */
export function attestAuditV2Tx(
  tx: Transaction,
  args: {
    auditExamplePkg: string;
    registryId: string;
    subject: string;
    score: number;
    reportUrl: string;
  },
): void {
  tx.moveCall({
    target: `${args.auditExamplePkg}::audit_v2::attest_audit_v2`,
    arguments: [
      tx.object(args.registryId),
      tx.pure.id(args.subject),
      tx.pure.u8(args.score),
      tx.pure.string(args.reportUrl),
    ],
  });
}

/**
 * Append `audit_example::audit::revoke_audit(admin, box, rcv)` to `tx` — the
 * admin-cap revocation policy: a holder of the `AuditAdminCap` revokes any
 * `Attestation<Audit>`. `auditExamplePkg` may be any version that defines the
 * `audit` module (the type and policy are stable across the upgrade).
 */
export function revokeAuditTx(
  tx: Transaction,
  args: {
    auditExamplePkg: string;
    adminCapId: string;
    boxId: string;
    attestationRef: { objectId: string; version: string; digest: string };
  },
): void {
  tx.moveCall({
    target: `${args.auditExamplePkg}::audit::revoke_audit`,
    arguments: [
      tx.object(args.adminCapId),
      tx.object(args.boxId),
      tx.receivingRef(args.attestationRef),
    ],
  });
}

/**
 * Fully-qualified Move type for `Attestation<Audit>`. Pass audit_example's
 * *original* id as `auditExamplePkg` — the v1 `Audit` type keeps the original
 * id across the upgrade.
 */
export function auditAttestationType(args: {
  attestationRegistryPkg: string;
  auditExamplePkg: string;
}): string {
  return `${args.attestationRegistryPkg}::attestation_registry::Attestation<${args.auditExamplePkg}::audit::Audit>`;
}

/**
 * Fully-qualified Move type for `Attestation<AuditV2>`. Pass audit_example's
 * *upgraded* (v2) id as `auditExamplePkg` — `AuditV2` is defined in the
 * upgrade, so its defining id is the v2 id.
 */
export function auditV2AttestationType(args: {
  attestationRegistryPkg: string;
  auditExamplePkg: string;
}): string {
  return `${args.attestationRegistryPkg}::attestation_registry::Attestation<${args.auditExamplePkg}::audit_v2::AuditV2>`;
}
