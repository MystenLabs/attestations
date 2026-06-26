import type { SuiGrpcClient } from '@mysten/sui/grpc';

export interface AttestationInfo {
  /** Object id of the `Attestation<T>` */
  id: string;
  /** Current object version (needed for `receivingRef` when revoking) */
  version: string;
  /** Object digest (needed for `receivingRef`) */
  digest: string;
  /** Fully qualified Move type, e.g. "0xPKG::attestation_registry::Attestation<0xAUD::audit::Audit>" */
  type: string;
  /** Raw BCS-encoded content of the attestation, if `includeContent` was requested */
  content?: Uint8Array;
  /** Server-rendered Display v2 output keyed by template field name */
  display?: Record<string, unknown>;
}

/**
 * Normalize the gRPC Display v2 payload to the flat field map that
 * `AttestationInfo.display` exposes. The client returns it wrapped as
 * `{ output: { ...fields }, errors }`; we surface just the fields.
 */
function displayFields(d: unknown): Record<string, unknown> {
  const out = (d as { output?: unknown } | null)?.output;
  return (out ?? d) as Record<string, unknown>;
}

/**
 * List every attestation owned by `boxAddr`. Pass `typeFilter` to use gRPC's
 * native server-side `StructType` filter — strictly cheaper than fetching all
 * and filtering client-side.
 *
 * `includeContent` and `includeDisplay` toggle the corresponding heavyweight
 * fields on each returned object; both default to false to keep the wire
 * payload small for enumeration use cases.
 */
export async function listAttestations(
  client: SuiGrpcClient,
  boxAddr: string,
  opts: {
    typeFilter?: string;
    includeContent?: boolean;
    includeDisplay?: boolean;
  } = {},
): Promise<AttestationInfo[]> {
  const out: AttestationInfo[] = [];
  let cursor: string | null = null;
  const include = {
    content: opts.includeContent ?? false,
    display: opts.includeDisplay ?? false,
  };
  do {
    const page: Awaited<ReturnType<typeof client.listOwnedObjects>> =
      await client.listOwnedObjects({
        owner: boxAddr,
        ...(opts.typeFilter !== undefined && { type: opts.typeFilter }),
        ...(cursor !== null && { cursor }),
        include,
      });
    for (const obj of page.objects) {
      out.push({
        id: obj.objectId,
        version: obj.version,
        digest: obj.digest,
        type: obj.type,
        ...(obj.content !== undefined && { content: obj.content as Uint8Array }),
        ...(obj.display != null && { display: displayFields(obj.display) }),
      });
    }
    cursor = page.hasNextPage ? page.cursor : null;
  } while (cursor !== null);
  return out;
}

/**
 * Fetch a single attestation by id, optionally including content and Display.
 */
export async function getAttestation(
  client: SuiGrpcClient,
  attestationId: string,
  opts: { includeContent?: boolean; includeDisplay?: boolean } = {},
): Promise<AttestationInfo> {
  const { object } = await client.getObject({
    objectId: attestationId,
    include: {
      content: opts.includeContent ?? false,
      display: opts.includeDisplay ?? false,
    },
  });
  return {
    id: object.objectId,
    version: object.version,
    digest: object.digest,
    type: object.type,
    ...(object.content !== undefined && { content: object.content as Uint8Array }),
    ...(object.display != null && { display: displayFields(object.display) }),
  };
}
