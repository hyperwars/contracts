// Toggle the deployer EOA between Hyperliquid small/big blocks.
// Usage:
//   node big-blocks.mjs on        (testnet)
//   node big-blocks.mjs off       (testnet)
//   node big-blocks.mjs on mainnet
//
// Reads DEPLOYER_PK from env.

import { privateKeyToAccount } from 'viem/accounts';
import * as hl from '@nktkas/hyperliquid';

const [mode, net = 'testnet'] = process.argv.slice(2);
if (mode !== 'on' && mode !== 'off') {
  console.error('first arg must be "on" or "off"');
  process.exit(1);
}
if (!process.env.DEPLOYER_PK) {
  console.error('DEPLOYER_PK env var required');
  process.exit(1);
}

const isTestnet = net !== 'mainnet';
const account = privateKeyToAccount(process.env.DEPLOYER_PK);
const transport = new hl.HttpTransport({ isTestnet });
const client = new hl.ExchangeClient({ wallet: account, transport });

const res = await client.evmUserModify({ usingBigBlocks: mode === 'on' });
console.log(`[${isTestnet ? 'testnet' : 'mainnet'}] big blocks ${mode}:`, res);
