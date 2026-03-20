/**
 * Full Polkadot Hub Testnet Check
 * Tests precompiles and deployed contracts
 */

const { ethers } = require('ethers');

const RPC_URL = 'https://eth-rpc-testnet.polkadot.io/';
const provider = new ethers.JsonRpcProvider(RPC_URL);

async function checkAll() {
  console.log('\n🔍 Testing Polkadot Hub Testnet\n');

  try {
    const blockNum = await provider.getBlockNumber();
    const chainId = (await provider.getNetwork()).chainId;
    console.log('✅ Connected! Block:', blockNum, '| Chain ID:', chainId.toString());
  } catch(e) {
    console.log('❌ Connection failed:', e.message);
    return;
  }

  console.log('\n--- Precompile Check (by code presence) ---');
  const precompiles = {
    'ecRecover (0x01)': '0x0000000000000000000000000000000000000001',
    'SHA256 (0x02)': '0x0000000000000000000000000000000000000002',
    'RIPEMD160 (0x03)': '0x0000000000000000000000000000000000000003',
    'Identity (0x04)': '0x0000000000000000000000000000000000000004',
    'ModExp (0x05)': '0x0000000000000000000000000000000000000005',
    'BN128 Add (0x06)': '0x0000000000000000000000000000000000000006',
    'BN128 Mul (0x07)': '0x0000000000000000000000000000000000000007',
    'BN128 Pairing (0x08)': '0x0000000000000000000000000000000000000008',
    'Blake2F (0x09)': '0x0000000000000000000000000000000000000009',
    'Ed25519 (0x402)': '0x0000000000000000000000000000000000000402',
    'Sr25519 (0x403)': '0x0000000000000000000000000000000000000403',
    'XCM (0x816)': '0x0000000000000000000000000000000000000816',
  };

  for (const [name, addr] of Object.entries(precompiles)) {
    try {
      const code = await provider.getCode(addr);
      const hasCode = code && code !== '0x' && code.length > 2;
      console.log(name.padEnd(25), hasCode ? '✅ HAS CODE' : '⚪ NO CODE (may still work)');
    } catch(e) {
      console.log(name.padEnd(25), '❌ ERROR');
    }
  }

  console.log('\n--- Precompile Function Tests ---');

  // Test ecRecover
  try {
    const hash = '0x456e9aea5e197a1f1af7a3e85a3212fa4049a3ba34c2289b4c860fc0b0c64ef3';
    const v = 28;
    const r = '0x9242685bf161793cc25603c231bc2f568eb630ea16aa137d2664ac8038825608';
    const s = '0x4f8ae3bd7535248d0bd448298cc2e2071e56992d0774dc340c368ae950852ada';
    const data = ethers.concat([
      hash,
      ethers.zeroPadValue(ethers.toBeHex(v), 32),
      r, s
    ]);
    const result = await provider.call({ to: '0x0000000000000000000000000000000000000001', data });
    console.log('ecRecover (0x01):'.padEnd(25), result && result.length > 2 ? '✅ WORKS' : '❌ FAILS');
  } catch(e) {
    console.log('ecRecover (0x01):'.padEnd(25), '❌ FAILS -', e.message.slice(0, 50));
  }

  // Test SHA256
  try {
    const data = '0x48656c6c6f'; // "Hello" in hex
    const result = await provider.call({ to: '0x0000000000000000000000000000000000000002', data });
    console.log('SHA256 (0x02):'.padEnd(25), result && result.length === 66 ? '✅ WORKS' : '❌ FAILS');
  } catch(e) {
    console.log('SHA256 (0x02):'.padEnd(25), '❌ FAILS -', e.message.slice(0, 50));
  }

  // Test Identity (should just return input)
  try {
    const data = '0x1234567890';
    const result = await provider.call({ to: '0x0000000000000000000000000000000000000004', data });
    console.log('Identity (0x04):'.padEnd(25), result === data ? '✅ WORKS' : '❌ FAILS');
  } catch(e) {
    console.log('Identity (0x04):'.padEnd(25), '❌ FAILS -', e.message.slice(0, 50));
  }

  console.log('\n--- Deployed Contract Check ---');
  const contracts = {
    'CryptoRegistry': '0x237259A349F258eD5d561F90dcb701f4371169B3',
    'StealthPayment': '0x98DB1edC0ED10888d559C641F709A364818B0167',
    'StealthVault': '0x5290EC1961854B8a45346f74BeF775E51d4Ba076',
    'OmniShieldEscrow': '0xFa10b866e5B4a3BDD2d0a978FCB5cAbb334372BE',
    'YieldRouter': '0xa4B00C51eD83c7a9E1F646E9C0329F4E61f651F1',
    'XcmRouter': '0x2BA3337232F5b1eA4b14f3ca0121C3272c25Bb4E',
    'OmniShieldHub': '0xCe7917f133B5f31807cC839DCC44f836D8ca7142',
  };

  for (const [name, addr] of Object.entries(contracts)) {
    try {
      const code = await provider.getCode(addr);
      const deployed = code && code !== '0x' && code.length > 2;
      console.log(name.padEnd(20), deployed ? '✅ DEPLOYED' : '❌ NOT DEPLOYED');
    } catch(e) {
      console.log(name.padEnd(20), '❌ ERROR');
    }
  }

  // If CryptoRegistry is deployed, check its precompile status
  const cryptoRegistryAddr = '0x237259A349F258eD5d561F90dcb701f4371169B3';
  const code = await provider.getCode(cryptoRegistryAddr);
  if (code && code !== '0x' && code.length > 2) {
    console.log('\n--- CryptoRegistry Precompile Status ---');
    const iface = new ethers.Interface([
      'function sr25519Available() view returns (bool)',
      'function ed25519Available() view returns (bool)',
      'function blake2fAvailable() view returns (bool)',
      'function bn128Available() view returns (bool)',
    ]);

    const checks = ['sr25519Available', 'ed25519Available', 'blake2fAvailable', 'bn128Available'];
    for (const fn of checks) {
      try {
        const result = await provider.call({
          to: cryptoRegistryAddr,
          data: iface.encodeFunctionData(fn)
        });
        const decoded = iface.decodeFunctionResult(fn, result);
        console.log(fn.padEnd(20), decoded[0] ? '✅ AVAILABLE' : '❌ NOT AVAILABLE');
      } catch(e) {
        console.log(fn.padEnd(20), '❌ CALL FAILED');
      }
    }
  }

  console.log('\n--- Summary ---');
  console.log('This tells us which PVM features we can actually USE for Track 2.\n');
}

checkAll().catch(console.error);
