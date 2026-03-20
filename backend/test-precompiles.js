/**
 * Test if PVM precompiles are actually deployed on Polkadot Hub
 * Run: node test-precompiles.js
 */

const { ethers } = require('ethers');

// CORRECT RPC for Polkadot Hub Testnet (Chain ID: 420420417)
const RPC_URL = 'https://eth-rpc-testnet.polkadot.io';
const provider = new ethers.JsonRpcProvider(RPC_URL);

const PRECOMPILES = {
  'Ed25519 Verify': '0x0000000000000000000000000000000000000402',
  'Sr25519 Verify': '0x0000000000000000000000000000000000000403',
  'Blake2F': '0x0000000000000000000000000000000000000009',
  'XCM Dispatch': '0x0000000000000000000000000000000000000816',
  'BN128 Add': '0x0000000000000000000000000000000000000006',
  'BN128 Mul': '0x0000000000000000000000000000000000000007',
  'BN128 Pairing': '0x0000000000000000000000000000000000000008',
};

async function checkPrecompile(name, address) {
  try {
    const code = await provider.getCode(address);
    const hasCode = code !== '0x';

    // Standard EVM precompiles (0x01-0x09) have no code but work
    const isStandardPrecompile = parseInt(address, 16) <= 9;

    if (hasCode) {
      console.log(`${name.padEnd(20)} ${address} ✅ DEPLOYED (has code)`);
    } else if (isStandardPrecompile) {
      // Test via actual call for standard precompiles
      console.log(`${name.padEnd(20)} ${address} 🔧 STANDARD (testing...)`);
    } else {
      console.log(`${name.padEnd(20)} ${address} ❌ NOT DEPLOYED`);
    }

    // For BN128 and Blake2F, try a real test call
    if (name.includes('BN128') || name === 'Blake2F') {
      try {
        let testData;
        if (name === 'Blake2F') {
          // Blake2F test: 12 rounds of compression
          testData = '0x0000000c' +
            '48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5' +
            'd182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b' +
            '6162630000000000000000000000000000000000000000000000000000000000' +
            '0000000000000000000000000000000000000000000000000000000000000000' +
            '0000000000000000000000000000000000000000000000000000000000000000' +
            '0000000000000000000000000000000000000000000000000000000000000000' +
            '0300000000000000' +
            '0000000000000001';
        } else if (name === 'BN128 Add') {
          // Test: G + G (add two generator points)
          testData = '0x' +
            '0000000000000000000000000000000000000000000000000000000000000001' +
            '0000000000000000000000000000000000000000000000000000000000000002' +
            '0000000000000000000000000000000000000000000000000000000000000001' +
            '0000000000000000000000000000000000000000000000000000000000000002';
        } else if (name === 'BN128 Mul') {
          // Test: 2 * G
          testData = '0x' +
            '0000000000000000000000000000000000000000000000000000000000000001' +
            '0000000000000000000000000000000000000000000000000000000000000002' +
            '0000000000000000000000000000000000000000000000000000000000000002';
        } else if (name === 'BN128 Pairing') {
          // Skip pairing test (complex input)
          return;
        }

        const result = await provider.call({
          to: address,
          data: testData
        });

        if (result && result !== '0x') {
          console.log(`  └─ Test call: ✅ WORKS (returned ${result.length} bytes)`);
        } else {
          console.log(`  └─ Test call: ❌ Empty response`);
        }
      } catch (e) {
        console.log(`  └─ Test call: ❌ FAILS (${e.message.slice(0, 60)})`);
      }
    }
  } catch (e) {
    console.log(`${name.padEnd(20)} ${address} ❌ ERROR: ${e.message}`);
  }
}

async function main() {
  console.log('\n🔍 Checking PVM Precompiles on Polkadot Hub\n');
  console.log('='.repeat(70));

  for (const [name, address] of Object.entries(PRECOMPILES)) {
    await checkPrecompile(name, address);
  }

  console.log('='.repeat(70));
  console.log('\n📊 Summary:');
  console.log('✅ = Precompile is available and usable');
  console.log('❌ = Precompile not deployed or not working\n');
}

main().catch(console.error);
