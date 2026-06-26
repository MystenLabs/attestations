import { SuiGrpcClient } from '@mysten/sui/grpc';

const DEFAULT_TESTNET_URL = 'https://fullnode.testnet.sui.io:443';

/**
 * Construct a `SuiGrpcClient` pointed at testnet by default. Pass `baseUrl`
 * to target a different endpoint (a fork, devnet, mainnet, etc.).
 */
export function makeClient(baseUrl: string = DEFAULT_TESTNET_URL): SuiGrpcClient {
  return new SuiGrpcClient({ network: 'testnet', baseUrl });
}
