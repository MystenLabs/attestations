/**
 * End-to-end CLI demo against a localnet (or any RPC):
 *   - create Boxes for two real published subjects: `dependency_example` and
 *     `subject_example` (which depends on it)
 *   - audit the dependency (Attestation<Audit>, v1 schema)
 *   - audit the subject with AuditV2 (the upgrade-added schema)
 *   - list + pretty-print the attestations with their Display rendering
 *   - revoke the dependency's audit and the subject's v1 audit, and show them
 *     leave the active box (revocation is by box membership — revoked
 *     attestations move to a separate sink address and stop appearing in the
 *     active-box query; the subject's AuditV2 stays as the live signal)
 *   - write `demo-ids.json` (registry id, subjects, trusted attesters) for the
 *     MVR Postgres seeder
 *
 * Run with:
 *   REGISTRY_ID=0x... pnpm demo [--rpc <url>] [--pubfile <path>]
 *
 * Defaults:
 *   - --rpc      http://127.0.0.1:9000 (a `sui start --with-faucet` localnet)
 *   - --pubfile  Pub.localnet.toml at the repo root
 *
 * Requires:
 *   - All packages test-published + audit_example upgraded via
 *     `scripts/test-publish.sh`, which writes the pubfile and prints REGISTRY_ID.
 *   - The sui CLI's keystore at `~/.sui/sui_config/sui.keystore`, with the
 *     active address funded on the target network.
 */

import { writeFileSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

import { Transaction } from '@mysten/sui/transactions';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { fromBase64, normalizeSuiAddress } from '@mysten/sui/utils';

import {
  boxAddress,
  createBoxTx,
  listAttestations,
  type AttestationInfo,
} from '../src/index.js';
import {
  attestAuditTx,
  attestAuditV2Tx,
  revokeAuditTx,
  auditAttestationType,
  auditV2AttestationType,
} from '../examples/audit.js';
import { makeClient } from './client.js';
import { readPubfile, type PublishedPackages } from './pubfile.js';

const KEYSTORE_PATH = join(homedir(), '.sui', 'sui_config', 'sui.keystore');
// demo.ts lives in ts/demo/, so repo root is two levels up.
const DEFAULT_PUBFILE_PATH = join(import.meta.dirname, '..', '..', 'Pub.localnet.toml');
const DEMO_IDS_PATH = join(import.meta.dirname, '..', '..', 'demo-ids.json');
const DEFAULT_RPC = 'http://127.0.0.1:9000';

function loadKeypair(): Ed25519Keypair {
  const raw = readFileSync(KEYSTORE_PATH, 'utf8');
  const keys: unknown = JSON.parse(raw);
  if (!Array.isArray(keys) || keys.length === 0 || typeof keys[0] !== 'string') {
    throw new Error(`unexpected keystore shape at ${KEYSTORE_PATH}`);
  }
  // Each entry: base64(flag-byte || 32-byte secret). Flag 0x00 == Ed25519.
  const decoded = fromBase64(keys[0]);
  if (decoded.length !== 33) {
    throw new Error(`expected 33-byte keystore entry (flag + key), got ${decoded.length}`);
  }
  if (decoded[0] !== 0) {
    throw new Error(`first keystore entry isn't Ed25519 (flag=${decoded[0]}); demo doesn't support others`);
  }
  return Ed25519Keypair.fromSecretKey(decoded.slice(1));
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`env var ${name} is required (see demo.ts docstring)`);
  return normalizeSuiAddress(v);
}

function printAttestation(att: AttestationInfo): void {
  console.log(`  id:      ${att.id}`);
  console.log(`  type:    ${att.type}`);
  if (att.display) {
    console.log('  display:');
    for (const [k, v] of Object.entries(att.display)) {
      console.log(`    ${k}: ${JSON.stringify(v)}`);
    }
  }
}

interface TxOk {
  digest: string;
  createdByType: Map<string, string[]>;
  createdRefs: Map<string, { objectId: string; version: string; digest: string }>;
}

async function exec(
  client: ReturnType<typeof makeClient>,
  signer: Ed25519Keypair,
  tx: Transaction,
): Promise<TxOk> {
  // sui-fork doesn't implement SimulateTransaction yet, which the SDK
  // would otherwise call to compute the gas budget. Set it explicitly so
  // build skips simulation.
  tx.setGasBudget(100_000_000n);
  const res = await client.signAndExecuteTransaction({
    signer,
    transaction: tx,
    include: { effects: true, objectTypes: true },
  });
  if (res.$kind !== 'Transaction') {
    throw new Error(`tx failed: ${JSON.stringify(res, null, 2)}`);
  }
  const t = res.Transaction;
  const status = t.status as { success: boolean; error: unknown };
  if (!status.success) {
    throw new Error(`tx ${t.digest} failed: ${JSON.stringify(t.status)}`);
  }
  // Wait for the tx to be visible across replicas before the next call
  // simulates against a snapshot that might not yet include it.
  await client.waitForTransaction({ digest: t.digest });
  const effects = t.effects;
  const objectTypes = t.objectTypes ?? {};
  const createdByType = new Map<string, string[]>();
  const createdRefs = new Map<string, { objectId: string; version: string; digest: string }>();
  for (const c of effects?.changedObjects ?? []) {
    if (c.idOperation !== 'Created') continue;
    const type = objectTypes[c.objectId];
    if (type !== undefined) {
      const arr = createdByType.get(type) ?? [];
      arr.push(c.objectId);
      createdByType.set(type, arr);
    }
    if (c.outputVersion !== null && c.outputDigest !== null) {
      createdRefs.set(c.objectId, {
        objectId: c.objectId,
        version: c.outputVersion,
        digest: c.outputDigest,
      });
    }
  }
  return { digest: t.digest, createdByType, createdRefs };
}

/** The single created object of `type`, or throw if not exactly one. */
function oneOf(ok: TxOk, type: string, label: string): string {
  const ids = ok.createdByType.get(type) ?? [];
  if (ids.length !== 1) {
    throw new Error(`expected exactly 1 ${label}, got ${ids.length} (type ${type})`);
  }
  return ids[0]!;
}

/** The single object of `type` owned by `owner`, or throw if not exactly one. */
async function findOwnedObject(
  client: ReturnType<typeof makeClient>,
  owner: string,
  type: string,
): Promise<string> {
  const page = await client.listOwnedObjects({ owner, type });
  const ids = page.objects.map((o) => o.objectId);
  if (ids.length !== 1) {
    throw new Error(`expected exactly 1 ${type} owned by ${owner}, got ${ids.length}`);
  }
  return ids[0]!;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      rpc: { type: 'string' },
      pubfile: { type: 'string' },
    },
  });

  const client = makeClient(values.rpc ?? DEFAULT_RPC);
  const signer = loadKeypair();
  const sender = signer.toSuiAddress();
  const pkgs: PublishedPackages = readPubfile(values.pubfile ?? DEFAULT_PUBFILE_PATH);
  const registryId = requireEnv('REGISTRY_ID');

  // `subject_example` pins dependency_example v1; v2 is a newer version it
  // hasn't pulled. We attest on both to exercise cross-version propagation —
  // a vuln on v2 is an upgrade-risk for the v1-pinning subject.
  const dependency = pkgs.dependencyExampleOriginal; // v1 — pinned by subject
  const dependencyV2 = pkgs.dependencyExample;        // v2 — latest
  const subject = pkgs.subjectExample;
  const dependencyBox = boxAddress(pkgs.attestationRegistry, registryId, dependency);
  const dependencyV2Box = boxAddress(pkgs.attestationRegistry, registryId, dependencyV2);
  const subjectBox = boxAddress(pkgs.attestationRegistry, registryId, subject);

  // Audit (v1) types use audit_example's ORIGINAL id; AuditV2 uses the v2 id.
  const auditType = auditAttestationType({
    attestationRegistryPkg: pkgs.attestationRegistry,
    auditExamplePkg: pkgs.auditExampleOriginal,
  });
  // The auditor's single-party revocation authority, created at publish and
  // owned by the publisher (sender). Type uses the *original* id (where the
  // `audit` module — and thus `AuditAdminCap` — is defined).
  const adminCapType = `${pkgs.auditExampleOriginal}::audit::AuditAdminCap`;
  const auditV2Type = auditV2AttestationType({
    attestationRegistryPkg: pkgs.attestationRegistry,
    auditExamplePkg: pkgs.auditExample,
  });
  const vulnType = `${pkgs.attestationRegistry}::attestation_registry::Attestation<${pkgs.vulnExample}::vuln::Vulnerability>`;

  console.log(`sender:          ${sender}`);
  console.log(`registry:        ${registryId}`);
  console.log(`dependency:      ${dependency}`);
  console.log(`  box:           ${dependencyBox}`);
  console.log(`subject:         ${subject}`);
  console.log(`  box:           ${subjectBox}`);

  console.log('\n▶ TX 1 — create_box for dependency v1, dependency v2, and subject');
  {
    const tx = new Transaction();
    createBoxTx(tx, { attestationRegistryPkg: pkgs.attestationRegistry, registryId, subject: dependency });
    createBoxTx(tx, { attestationRegistryPkg: pkgs.attestationRegistry, registryId, subject: dependencyV2 });
    createBoxTx(tx, { attestationRegistryPkg: pkgs.attestationRegistry, registryId, subject });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ TX 2 — attest_audit on dependency (score=90, will be revoked)');
  let depAuditId: string;
  let depAuditRef: { objectId: string; version: string; digest: string };
  {
    const tx = new Transaction();
    attestAuditTx(tx, { auditExamplePkg: pkgs.auditExample, registryId, subject: dependency, score: 90, reportUrl: 'https://audits.example.com/dependency-v1.pdf' });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    depAuditId = oneOf(ok, auditType, 'Attestation<Audit>');
    depAuditRef = ok.createdRefs.get(depAuditId)!;
  }

  console.log('\n▶ TX 2b — attest_vuln on dependency (effective; propagates to the subject)');
  let dependencyVulnId: string;
  {
    const tx = new Transaction();
    const [cap] = tx.moveCall({
      target: `${pkgs.vulnExample}::vuln::attest_vuln`,
      arguments: [
        tx.object(registryId),
        tx.pure.id(dependency),
        tx.pure.u8(7),
        tx.pure.string('CVE-2026-0042'),
        tx.pure.string('Heap overflow in the dependency'),
        tx.pure.string('https://scanner.example.com/CVE-2026-0042'),
      ],
    });
    tx.transferObjects([cap!], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    dependencyVulnId = oneOf(ok, vulnType, 'Attestation<Vulnerability>');
  }

  console.log('\n▶ TX 2c — attest_vuln on dependency v2 (newer than the pinned v1 → upgrade-risk)');
  let dependencyV2VulnId: string;
  {
    const tx = new Transaction();
    const [cap] = tx.moveCall({
      target: `${pkgs.vulnExample}::vuln::attest_vuln`,
      arguments: [
        tx.object(registryId),
        tx.pure.id(dependencyV2),
        tx.pure.u8(8),
        tx.pure.string('CVE-2026-0099'),
        tx.pure.string('Auth bypass introduced in dependency v2'),
        tx.pure.string('https://scanner.example.com/CVE-2026-0099'),
      ],
    });
    tx.transferObjects([cap!], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    dependencyV2VulnId = oneOf(ok, vulnType, 'Attestation<Vulnerability>');
  }

  console.log('\n▶ TX 3 — attest_audit_v2 on subject (score=95)');
  let subjectAuditId: string;
  {
    const tx = new Transaction();
    attestAuditV2Tx(tx, {
      auditExamplePkg: pkgs.auditExample,
      registryId,
      subject,
      score: 95,
      reportUrl: 'https://audits.example.com/subject-v1.pdf',
    });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    subjectAuditId = oneOf(ok, auditV2Type, 'Attestation<AuditV2>');
  }

  console.log('\n▶ TX 3b — attest_audit on subject (score=88, will be revoked)');
  let subjectAuditV1Ref: { objectId: string; version: string; digest: string };
  {
    const tx = new Transaction();
    attestAuditTx(tx, { auditExamplePkg: pkgs.auditExample, registryId, subject, score: 88, reportUrl: 'https://audits.example.com/subject-v1.pdf' });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    const id = oneOf(ok, auditType, 'Attestation<Audit>');
    subjectAuditV1Ref = ok.createdRefs.get(id)!;
  }

  console.log("\n▶ TX 3c — attest_vuln on subject (severity=4, the package's own vuln)");
  let subjectVulnId: string;
  {
    const tx = new Transaction();
    const [cap] = tx.moveCall({
      target: `${pkgs.vulnExample}::vuln::attest_vuln`,
      arguments: [
        tx.object(registryId),
        tx.pure.id(subject),
        tx.pure.u8(4),
        tx.pure.string('CVE-2026-0001'),
        tx.pure.string('Example informational finding'),
        tx.pure.string('https://scanner.example.com/CVE-2026-0001'),
      ],
    });
    tx.transferObjects([cap!], sender);
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    subjectVulnId = oneOf(ok, vulnType, 'Attestation<Vulnerability>');
  }

  console.log('\n▶ TX 3d — attest_self_pull on subject (author recall, via its UpgradeCap)');
  let subjectSelfPullId: string;
  {
    const tx = new Transaction();
    tx.moveCall({
      target: `${pkgs.selfPull}::self_pull::attest_self_pull`,
      arguments: [
        tx.object(registryId),
        tx.object(pkgs.subjectUpgradeCap),
        tx.pure.string('Critical bug discovered by the maintainers; do not use.'),
      ],
    });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
    const selfPullType = `${pkgs.attestationRegistry}::attestation_registry::Attestation<${pkgs.selfPull}::self_pull::SelfPull>`;
    subjectSelfPullId = oneOf(ok, selfPullType, 'Attestation<SelfPull>');
  }

  // Negative test data: two attestations a trust consumer must filter out — one
  // from an untrusted attester (filtered on the package), one of a trusted
  // package's type with no registered Display (filtered on the Display-gate).
  console.log('\n▶ TX 4 — attest_untrusted + attest_internal_note (both should be filtered out)');
  {
    const tx = new Transaction();
    tx.moveCall({
      target: `${pkgs.untrustedExample}::untrusted::attest_untrusted`,
      arguments: [tx.object(registryId), tx.pure.id(subject), tx.pure.string('not whitelisted')],
    });
    tx.moveCall({
      target: `${pkgs.auditExample}::audit_v2::attest_internal_note`,
      arguments: [tx.object(registryId), tx.pure.id(subject), tx.pure.string('no Display registered')],
    });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('\n▶ Read — all attestations on subject');
  for (const att of await listAttestations(client, subjectBox, { includeDisplay: true })) {
    console.log('');
    printAttestation(att);
  }

  // Revocation is by box membership: a revoked attestation is moved out of the
  // active box, so it stops appearing in this query.
  const reportActiveAudits = async (label: string) => {
    for (const [who, box] of [
      ['dependency', dependencyBox],
      ['subject', subjectBox],
    ] as const) {
      const ids = (
        await listAttestations(client, box, { typeFilter: auditType })
      ).map((a) => a.id);
      console.log(
        `▶ ${label}: Attestation<Audit> in ${who}'s active box = ${ids.length} ${JSON.stringify(ids)}`,
      );
    }
  };

  console.log('');
  await reportActiveAudits('Before revoke');

  console.log("\n▶ TX 5 — revoke the dependency audit and the subject's v1 audit (via AuditAdminCap)");
  {
    const adminCapId = await findOwnedObject(client, sender, adminCapType);
    const tx = new Transaction();
    revokeAuditTx(tx, {
      auditExamplePkg: pkgs.auditExample,
      adminCapId,
      boxId: dependencyBox,
      attestationRef: depAuditRef,
    });
    revokeAuditTx(tx, {
      auditExamplePkg: pkgs.auditExample,
      adminCapId,
      boxId: subjectBox,
      attestationRef: subjectAuditV1Ref,
    });
    const ok = await exec(client, signer, tx);
    console.log(`  digest: ${ok.digest}`);
  }

  console.log('');
  await reportActiveAudits('After revoke');

  // Hand-off for the MVR Postgres seeder.
  const demoIds = {
    registryId,
    attestationRegistryPkg: pkgs.attestationRegistry,
    subjects: { subject, dependency },
    trustedAttestors: [
      { name: 'audit_example', originalId: pkgs.auditExampleOriginal, latestId: pkgs.auditExample },
      { name: 'vuln_example', originalId: pkgs.vulnExample, latestId: pkgs.vulnExample },
      { name: 'self_pull', originalId: pkgs.selfPull, latestId: pkgs.selfPull },
    ],
    createdAttestations: {
      dependencyAudit: depAuditId,
      dependencyVuln: dependencyVulnId,
      dependencyV2Vuln: dependencyV2VulnId,
      subjectAuditV2: subjectAuditId,
      subjectVuln: subjectVulnId,
      subjectSelfPull: subjectSelfPullId,
    },
  };
  writeFileSync(DEMO_IDS_PATH, JSON.stringify(demoIds, null, 2) + '\n');
  console.log(`\n▶ wrote ${DEMO_IDS_PATH}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
