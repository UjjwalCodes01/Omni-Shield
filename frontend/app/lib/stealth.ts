/**
 * OmniShield Stealth Payment Library — Production Implementation
 *
 * Implements the full EIP-5564 compatible stealth payment flow using
 * real secp256k1 elliptic curve cryptography:
 *
 *   1. Generate stealth meta-address (spending + viewing keypairs on secp256k1)
 *   2. Compute one-time stealth address via real ECDH + EC point addition
 *   3. Compute view tags for efficient O(1) announcement scanning
 *   4. Scan StealthPaymentSent events to discover received payments (real token/amount)
 *   5. Derive stealth private key for withdrawal using EC scalar addition
 *
 * Privacy model:
 *   - Sender performs ECDH: sharedSecret = ephemeralPrivKey * viewingPubKey  (curve multiplication)
 *   - Stealth public key = spendingPubKey + hash(sharedSecret) * G          (curve addition)
 *   - Only the recipient can derive the stealth private key:
 *       stealthPrivKey = spendingPrivKey + hash(sharedSecret)               (scalar addition mod n)
 *   - View tags enable 256x scanning speedup (1 byte filter before full derivation)
 *
 * On-chain storage convention:
 *   - Public keys are stored as bytes32 = x-coordinate of the compressed secp256k1 key
 *   - Even parity (0x02 prefix) is enforced at key generation time
 *   - Off-chain, reconstruct compressed key as: 0x02 || xCoordinate
 */

import { ethers } from "ethers";
import { secp256k1 } from "@noble/curves/secp256k1.js";

// ============================================================================
// Types
// ============================================================================

/** Stealth meta-address: the public keys a recipient publishes */
export interface StealthMetaAddress {
  /** x-coordinate of compressed spending public key (32 bytes hex, even parity) */
  spendingPubKey: string;
  /** x-coordinate of compressed viewing public key (32 bytes hex, even parity) */
  viewingPubKey: string;
}

/** Full stealth keypair for a recipient */
export interface StealthKeyPair {
  /** The meta-address (public) */
  metaAddress: StealthMetaAddress;
  /** Spending private key (32 bytes hex) — KEEP SECRET */
  spendingPrivateKey: string;
  /** Viewing private key (32 bytes hex) — can share with scanner */
  viewingPrivateKey: string;
}

/** Result of computing a stealth payment */
export interface StealthPaymentData {
  /** The one-time stealth address (real EC-derived, has a known private key) */
  stealthAddress: string;
  /** x-coordinate of ephemeral public key (bytes32, even parity, for announcement) */
  ephemeralPubKey: string;
  /** View tag for efficient scanning (1 byte, 0-255) */
  viewTag: number;
  /** Hash of the ECDH shared secret (used for on-chain helpers) */
  sharedSecretHash: string;
}

/** A scanned announcement that matched the viewing key */
export interface ScannedPayment {
  /** The stealth address that received funds */
  stealthAddress: string;
  /** Token address (0x0 for native) */
  token: string;
  /** Amount received (in wei) */
  amount: bigint;
  /** x-coordinate of ephemeral public key from the announcement */
  ephemeralPubKey: string;
  /** View tag */
  viewTag: number;
  /** Block number of the announcement */
  blockNumber: number;
  /** Transaction hash */
  txHash: string;
}

// ============================================================================
// Constants
// ============================================================================

/** secp256k1 curve order (well-known constant, same across all implementations) */
const CURVE_ORDER = BigInt(
  "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"
);

/** Polkadot Hub TestNet configuration */
export const POLKADOT_HUB_TESTNET = {
  chainId: 420420417,
  rpcUrl: "https://eth-rpc-testnet.polkadot.io/",
  name: "Polkadot Hub TestNet",
};

/** Deployed contract addresses (V6 — production-ready with real ECDH + vault delegation) */
export const CONTRACT_ADDRESSES = {
  escrow: "0xFa10b866e5B4a3BDD2d0a978FCB5cAbb334372BE",
  stealthPayment: "0x98DB1edC0ED10888d559C641F709A364818B0167",
  stealthVault: "0x5290EC1961854B8a45346f74BeF775E51d4Ba076",
  yieldRouter: "0xa4B00C51eD83c7a9E1F646E9C0329F4E61f651F1",
  xcmRouter: "0x2BA3337232F5b1eA4b14f3ca0121C3272c25Bb4E",
  cryptoRegistry: "0x237259A349F258eD5d561F90dcb701f4371169B3",
  omniShieldHub: "0xCe7917f133B5f31807cC839DCC44f836D8ca7142",
};

// ============================================================================
// Key Generation (Real secp256k1)
// ============================================================================

/**
 * Ensure a secp256k1 private key produces a public key with even parity (0x02 prefix).
 * If the key has odd parity, negate it: newPrivKey = curveOrder - privKey.
 * This convention allows storing just the x-coordinate (32 bytes) on-chain,
 * and reconstructing the full compressed key by prepending 0x02.
 */
function ensureEvenParity(privateKeyHex: string): string {
  const signingKey = new ethers.SigningKey(privateKeyHex);
  const compressed = signingKey.compressedPublicKey; // 0x02... or 0x03...

  if (compressed.startsWith("0x02")) {
    return privateKeyHex;
  }

  // Negate the key to flip parity
  const privBig = BigInt(privateKeyHex);
  const negated = CURVE_ORDER - privBig;
  return "0x" + negated.toString(16).padStart(64, "0");
}

/**
 * Get the x-coordinate of a private key's public key (32 bytes, even parity enforced).
 */
function pubKeyXCoord(privateKeyHex: string): string {
  const signingKey = new ethers.SigningKey(privateKeyHex);
  // compressedPublicKey is 0x02 + 32 bytes x-coordinate
  return "0x" + signingKey.compressedPublicKey.slice(4);
}

/**
 * Reconstruct a full compressed public key from an x-coordinate stored on-chain.
 * Convention: even parity (0x02 prefix).
 */
function xCoordToCompressed(xCoord: string): string {
  return "0x02" + xCoord.slice(2);
}

/**
 * Generate a complete stealth keypair for a recipient.
 *
 * Creates two independent secp256k1 keypairs with even parity enforced:
 *   - Spending keypair: Controls the stealth address funds (MUST stay secret)
 *   - Viewing keypair: Used to scan for payments (can be delegated to a scanner)
 *
 * @returns Full stealth keypair with meta-address and private keys
 */
export function generateStealthKeyPair(): StealthKeyPair {
  // Generate random private keys
  let spendingPrivKey = ethers.hexlify(ethers.randomBytes(32));
  let viewingPrivKey = ethers.hexlify(ethers.randomBytes(32));

  // Enforce even parity convention
  spendingPrivKey = ensureEvenParity(spendingPrivKey);
  viewingPrivKey = ensureEvenParity(viewingPrivKey);

  return {
    metaAddress: {
      spendingPubKey: pubKeyXCoord(spendingPrivKey),
      viewingPubKey: pubKeyXCoord(viewingPrivKey),
    },
    spendingPrivateKey: spendingPrivKey,
    viewingPrivateKey: viewingPrivKey,
  };
}

// ============================================================================
// Stealth Address Computation (Real ECDH + EC Point Addition)
// ============================================================================

/**
 * Compute a one-time stealth address for sending a payment.
 *
 * Real secp256k1 flow:
 *   1. Generate ephemeral keypair (even parity)
 *   2. ECDH: sharedSecret = ephemeralPrivKey * viewingPubKey (curve point multiplication)
 *   3. Hash the shared secret: h = keccak256(sharedSecret)
 *   4. Stealth public key = spendingPubKey + h * G (EC point addition)
 *   5. Stealth address = address(stealthPubKey)
 *   6. View tag = first byte of keccak256(sharedSecretBytes)
 *
 * @param recipientMeta - Recipient's stealth meta-address (x-coordinates)
 * @returns Stealth payment data needed to send the payment
 */
export function computeStealthPayment(
  recipientMeta: StealthMetaAddress
): StealthPaymentData {
  // Step 1: Generate ephemeral keypair with even parity
  let ephemeralPrivKey = ethers.hexlify(ethers.randomBytes(32));
  ephemeralPrivKey = ensureEvenParity(ephemeralPrivKey);
  const ephemeralSigningKey = new ethers.SigningKey(ephemeralPrivKey);

  // Step 2: Real ECDH — shared secret point
  const viewingCompressed = xCoordToCompressed(recipientMeta.viewingPubKey);
  const sharedSecretPoint = ephemeralSigningKey.computeSharedSecret(viewingCompressed);
  // sharedSecretPoint is a compressed point (33 bytes hex string)

  // Step 3: Hash the shared secret to get a scalar
  const hashedSecret = ethers.keccak256(sharedSecretPoint);

  // Step 4: Stealth public key = spendingPubKey + hash(sharedSecret) * G
  const spendingCompressed = xCoordToCompressed(recipientMeta.spendingPubKey);
  const spendingPoint = secp256k1.Point.fromHex(
    spendingCompressed.slice(2) // remove 0x prefix
  );

  // Reduce hash to valid scalar (mod curve order)
  const offsetScalar = BigInt(hashedSecret) % CURVE_ORDER;
  const offsetPoint = secp256k1.Point.BASE.multiply(offsetScalar);
  const stealthPoint = spendingPoint.add(offsetPoint);

  // Step 5: Derive stealth address from the uncompressed stealth public key
  const stealthPubKeyBytes = stealthPoint.toBytes(false); // 65 bytes, 0x04 prefix
  const stealthAddress = ethers.computeAddress(ethers.hexlify(stealthPubKeyBytes));

  // Step 6: View tag = first byte of keccak256(sharedSecretPoint)
  const viewTag = computeViewTag(sharedSecretPoint);

  // Ephemeral public key x-coordinate for the announcement
  const ephemeralPubKeyXCoord = pubKeyXCoord(ephemeralPrivKey);

  return {
    stealthAddress,
    ephemeralPubKey: ephemeralPubKeyXCoord,
    viewTag,
    sharedSecretHash: hashedSecret,
  };
}

/**
 * Derive the stealth private key so the recipient can withdraw funds.
 *
 * stealthPrivKey = (spendingPrivKey + keccak256(sharedSecret)) mod curveOrder
 *
 * @param spendingPrivateKey - Recipient's spending private key
 * @param viewingPrivateKey - Recipient's viewing private key
 * @param ephemeralPubKeyXCoord - x-coordinate of ephemeral pub key (from announcement)
 * @returns The stealth private key (can create a Wallet to sign transactions)
 */
export function deriveStealthPrivateKey(
  spendingPrivateKey: string,
  viewingPrivateKey: string,
  ephemeralPubKeyXCoord: string
): string {
  // 1. Reconstruct ECDH shared secret
  const viewingKey = new ethers.SigningKey(viewingPrivateKey);
  const ephemeralCompressed = xCoordToCompressed(ephemeralPubKeyXCoord);
  const sharedSecretPoint = viewingKey.computeSharedSecret(ephemeralCompressed);

  // 2. Hash the shared secret
  const hashedSecret = ethers.keccak256(sharedSecretPoint);

  // 3. Stealth private key = (spendingPrivKey + hashedSecret) mod curveOrder
  const spendBig = BigInt(spendingPrivateKey);
  const offsetBig = BigInt(hashedSecret) % CURVE_ORDER;
  const stealthPrivBig = (spendBig + offsetBig) % CURVE_ORDER;

  return "0x" + stealthPrivBig.toString(16).padStart(64, "0");
}

/**
 * Verify that a stealth address matches the expected derivation.
 * Useful for debugging and test validation.
 *
 * @param spendingPubKeyXCoord - Recipient's spending pub key x-coordinate
 * @param sharedSecretHash - keccak256(sharedSecret)
 * @returns The expected stealth address
 */
export function deriveStealthAddress(
  spendingPubKeyXCoord: string,
  sharedSecretHash: string
): string {
  const spendingCompressed = xCoordToCompressed(spendingPubKeyXCoord);
  const spendingPoint = secp256k1.Point.fromHex(
    spendingCompressed.slice(2)
  );

  const offsetScalar = BigInt(sharedSecretHash) % CURVE_ORDER;
  const offsetPoint = secp256k1.Point.BASE.multiply(offsetScalar);
  const stealthPoint = spendingPoint.add(offsetPoint);

  const stealthPubKeyBytes = stealthPoint.toBytes(false);
  return ethers.computeAddress(ethers.hexlify(stealthPubKeyBytes));
}

/**
 * Compute a view tag from a shared secret.
 * First byte of keccak256(sharedSecret).
 *
 * @param sharedSecret - The ECDH shared secret (compressed point hex)
 * @returns View tag (0-255)
 */
export function computeViewTag(sharedSecret: string): number {
  const hash = ethers.keccak256(sharedSecret);
  return parseInt(hash.slice(2, 4), 16);
}

// ============================================================================
// Announcement Scanning (Real Data — Parses Token & Amount)
// ============================================================================

/**
 * Scan StealthPaymentSent events to find payments addressed to this recipient.
 *
 * Uses StealthPaymentSent events which contain real token + amount data.
 *
 * Scanning process:
 *   1. Fetch all StealthPaymentSent events in the block range
 *   2. For each event, reconstruct the ECDH shared secret:
 *      sharedSecret = viewingPrivKey * ephemeralPubKey
 *   3. Compute view tag — if mismatch, skip (256x speedup)
 *   4. Compute full stealth address via EC point addition
 *   5. If stealth address matches the event, this payment is ours
 *   6. Return with real token address and amount from the event
 *
 * @param provider - Ethers provider
 * @param stealthPaymentAddress - StealthPayment contract address
 * @param viewingPrivateKey - Recipient's viewing private key
 * @param spendingPubKeyXCoord - Recipient's spending pub key x-coordinate
 * @param fromBlock - Block to start scanning from
 * @param toBlock - Block to scan to (default: "latest")
 * @returns Array of matched payments with real token/amount data
 */
export async function scanForPayments(
  provider: ethers.Provider,
  stealthPaymentAddress: string,
  viewingPrivateKey: string,
  spendingPubKeyXCoord: string,
  fromBlock: number,
  toBlock: number | "latest" = "latest"
): Promise<ScannedPayment[]> {
  // Query StealthPaymentSent events — has token + amount as non-indexed fields
  const stealthPaymentSentTopic = ethers.id(
    "StealthPaymentSent(address,bytes32,address,uint256,uint8)"
  );

  const logs = await provider.getLogs({
    address: stealthPaymentAddress,
    topics: [stealthPaymentSentTopic],
    fromBlock,
    toBlock,
  });

  const iface = new ethers.Interface([
    "event StealthPaymentSent(address indexed stealthAddress, bytes32 indexed ephemeralPubKey, address token, uint256 amount, uint8 viewTag)",
  ]);

  const viewingKey = new ethers.SigningKey(viewingPrivateKey);
  const payments: ScannedPayment[] = [];

  for (const log of logs) {
    try {
      const parsed = iface.parseLog({
        topics: log.topics as string[],
        data: log.data,
      });
      if (!parsed) continue;

      const logStealthAddr: string = parsed.args.stealthAddress;
      const ephemeralXCoord: string = parsed.args.ephemeralPubKey; // bytes32 = x-coordinate
      const token: string = parsed.args.token;
      const amount: bigint = parsed.args.amount;
      const logViewTag: number = Number(parsed.args.viewTag);

      // Reconstruct shared secret via ECDH
      const ephemeralCompressed = xCoordToCompressed(ephemeralXCoord);

      let sharedSecretPoint: string;
      try {
        sharedSecretPoint = viewingKey.computeSharedSecret(ephemeralCompressed);
      } catch {
        // Invalid point — skip this log
        continue;
      }

      // Quick view tag check (256x speedup)
      const expectedViewTag = computeViewTag(sharedSecretPoint);
      if (expectedViewTag !== logViewTag) continue;

      // Full stealth address derivation via EC point addition
      const hashedSecret = ethers.keccak256(sharedSecretPoint);
      const expectedStealth = deriveStealthAddress(
        spendingPubKeyXCoord,
        hashedSecret
      );

      if (expectedStealth.toLowerCase() === logStealthAddr.toLowerCase()) {
        payments.push({
          stealthAddress: logStealthAddr,
          token,
          amount,
          ephemeralPubKey: ephemeralXCoord,
          viewTag: expectedViewTag,
          blockNumber: log.blockNumber,
          txHash: log.transactionHash,
        });
      }
    } catch {
      // Skip malformed logs
      continue;
    }
  }

  return payments;
}

// ============================================================================
// Commitment Helpers (StealthVault)
// ============================================================================

/**
 * Compute a commitment for the StealthVault.
 * Matches the on-chain verification: C = keccak256(amount || blindingFactor || depositor)
 *
 * @param amount - Deposit amount in wei
 * @param blindingFactor - Random blinding factor (bytes32)
 * @param depositor - Depositor address
 * @returns Commitment hash (bytes32)
 */
export function computeCommitment(
  amount: bigint,
  blindingFactor: string,
  depositor: string
): string {
  return ethers.keccak256(
    ethers.solidityPacked(
      ["uint256", "bytes32", "address"],
      [amount, blindingFactor, depositor]
    )
  );
}

/**
 * Generate a random blinding factor for commitment deposits.
 *
 * @returns Random bytes32 hex string
 */
export function generateBlindingFactor(): string {
  return ethers.hexlify(ethers.randomBytes(32));
}

/**
 * Compute a nullifier for withdrawal.
 *
 * @param secret - The withdrawal secret
 * @param depositIndex - The deposit index
 * @returns Nullifier hash (bytes32)
 */
export function computeNullifier(
  secret: string,
  depositIndex: number
): string {
  return ethers.keccak256(
    ethers.solidityPacked(["bytes32", "uint256"], [secret, depositIndex])
  );
}

// ============================================================================
// Relayer Withdrawal Helpers
// ============================================================================

/** Domain separator for StealthPayment relayer withdrawal signatures */
const SP_WITHDRAWAL_DOMAIN = ethers.keccak256(
  ethers.toUtf8Bytes("OmniShield::StealthWithdrawal::v1")
);

/** Domain separator for StealthVault relayer withdrawal signatures */
const VAULT_WITHDRAWAL_DOMAIN = ethers.keccak256(
  ethers.toUtf8Bytes("OmniShield::StealthVault::v1")
);

/**
 * Sign a relayer withdrawal request (for StealthPayment.withdrawViaRelayer).
 *
 * @param stealthWallet - Wallet for the stealth address (has the derived private key)
 * @param token - Token address (0x0 for native)
 * @param to - Final destination address
 * @param relayerFee - Fee for the relayer (in wei)
 * @param deadline - Timestamp deadline
 * @param chainId - Chain ID
 * @returns Signature components (v, r, s) and the withdrawal hash
 */
export async function signRelayerWithdrawal(
  stealthWallet: ethers.Wallet,
  token: string,
  to: string,
  relayerFee: bigint,
  deadline: number,
  chainId: number
): Promise<{ v: number; r: string; s: string; hash: string }> {
  const withdrawalHash = ethers.keccak256(
    ethers.solidityPacked(
      [
        "bytes32",
        "address",
        "address",
        "address",
        "uint256",
        "uint256",
        "uint256",
      ],
      [
        SP_WITHDRAWAL_DOMAIN,
        stealthWallet.address,
        token,
        to,
        relayerFee,
        deadline,
        chainId,
      ]
    )
  );

  // EIP-191 personal sign
  const signature = await stealthWallet.signMessage(
    ethers.getBytes(withdrawalHash)
  );
  const sig = ethers.Signature.from(signature);

  return { v: sig.v, r: sig.r, s: sig.s, hash: withdrawalHash };
}

/**
 * Sign a vault relayer withdrawal request (for StealthVault.withdrawViaRelayer).
 *
 * @param stealthWallet - Wallet for the stealth address
 * @param token - Token address (0x0 for native)
 * @param to - Final destination address
 * @param relayerFee - Fee for the relayer
 * @param deadline - Timestamp deadline
 * @param chainId - Chain ID
 * @returns Signature components and hash
 */
export async function signVaultRelayerWithdrawal(
  stealthWallet: ethers.Wallet,
  token: string,
  to: string,
  relayerFee: bigint,
  deadline: number,
  chainId: number
): Promise<{ v: number; r: string; s: string; hash: string }> {
  const withdrawalHash = ethers.keccak256(
    ethers.solidityPacked(
      [
        "bytes32",
        "address",
        "address",
        "address",
        "uint256",
        "uint256",
        "uint256",
      ],
      [
        VAULT_WITHDRAWAL_DOMAIN,
        stealthWallet.address,
        token,
        to,
        relayerFee,
        deadline,
        chainId,
      ]
    )
  );

  const signature = await stealthWallet.signMessage(
    ethers.getBytes(withdrawalHash)
  );
  const sig = ethers.Signature.from(signature);

  return { v: sig.v, r: sig.r, s: sig.s, hash: withdrawalHash };
}

// ============================================================================
// Contract Interaction Helpers
// ============================================================================

/** Minimal ABI for StealthPayment contract */
export const STEALTH_PAYMENT_ABI = [
  "function registerStealthMetaAddress(bytes32 spendingPubKey, bytes32 viewingPubKey) external",
  "function sendNativeToStealth(address stealthAddress, bytes32 ephemeralPubKey, uint8 viewTag, bytes metadata) external payable",
  "function sendTokenToStealth(address token, uint256 amount, address stealthAddress, bytes32 ephemeralPubKey, uint8 viewTag, bytes metadata) external",
  "function withdrawFromStealth(address token, address to) external",
  "function withdrawViaRelayer(address stealthAddress, address token, address to, uint256 relayerFee, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external",
  "function withdrawOnBehalf(address stealthAddress, address token, address to, uint256 relayerFee, address relayerAddr) external",
  "function batchSendNativeToStealth(tuple(address stealthAddress, bytes32 ephemeralPubKey, uint8 viewTag, uint256 amount)[] entries, bytes metadata) external payable",
  "function batchSendTokenToStealth(address token, tuple(address stealthAddress, bytes32 ephemeralPubKey, uint8 viewTag, uint256 amount)[] entries, bytes metadata) external",
  "function getStealthMetaAddress(address user) external view returns (tuple(bytes32 spendingPubKey, bytes32 viewingPubKey, bool isRegistered))",
  "function getStealthBalance(address stealthAddress, address token) external view returns (uint256)",
  "function getAnnouncementCount() external view returns (uint256)",
  "function isStealthAddressUsed(address stealthAddress) external view returns (bool)",
  "function computeViewTag(bytes32 sharedSecret) external pure returns (uint8)",
  "function computeStealthAddress(bytes32 spendingPubKey, bytes32 sharedSecretHash) external pure returns (address)",
  "function authorizedVault() external view returns (address)",
  "event Announcement(uint256 indexed schemeId, address indexed stealthAddress, address indexed caller, bytes32 ephemeralPubKey, bytes metadata)",
  "event StealthPaymentSent(address indexed stealthAddress, bytes32 indexed ephemeralPubKey, address token, uint256 amount, uint8 viewTag)",
  "event StealthWithdrawal(address indexed stealthAddress, address indexed to, address token, uint256 amount)",
  "event RelayerWithdrawalProcessed(address indexed stealthAddress, address indexed to, address indexed relayer, address token, uint256 amount, uint256 relayerFee)",
];

/** Minimal ABI for StealthVault contract */
export const STEALTH_VAULT_ABI = [
  "function depositWithCommitment(bytes32 commitment) external payable",
  "function depositTokenWithCommitment(address token, uint256 amount, bytes32 commitment) external",
  "function withdrawWithNullifier(bytes32 nullifier, uint256 depositIndex, uint256 amount, bytes32 blindingFactor, address to) external",
  "function withdrawViaRelayer(tuple(address stealthAddress, address token, address to, uint256 relayerFee, uint256 deadline) withdrawal, uint8 v, bytes32 r, bytes32 s) external",
  "function batchSendNativeToStealth(tuple(address stealthAddress, uint256 amount, bytes32 ephemeralPubKey, uint8 viewTag)[] payments, bytes metadata) external payable",
  "function batchSendTokenToStealth(address token, tuple(address stealthAddress, uint256 amount, bytes32 ephemeralPubKey, uint8 viewTag)[] payments, bytes metadata) external",
  "function initiateEmergencyWithdrawal(uint256 depositIndex) external",
  "function executeEmergencyWithdrawal(uint256 depositIndex, uint256 amount, bytes32 blindingFactor) external",
  "function computeViewTag(bytes32 sharedSecret) external pure returns (uint8 viewTag)",
  "function computeStealthAddress(bytes32 spendingPubKey, bytes32 sharedSecretHash) external pure returns (address)",
  "function getDepositCount() external view returns (uint256)",
  "function getDeposit(uint256 index) external view returns (tuple(bytes32 commitment, address token, uint64 timestamp, bool withdrawn))",
  "function isNullifierUsed(bytes32 nullifier) external view returns (bool)",
  "function relayerFeeCap() external view returns (uint256)",
  "function emergencyTimelock() external view returns (uint256)",
  "event CommitmentDeposited(uint256 indexed depositIndex, bytes32 indexed commitment, address token, uint256 amount, uint64 timestamp)",
  "event NullifierWithdrawal(bytes32 indexed nullifier, address indexed to, address token, uint256 amount, address relayer)",
  "event BatchStealthProcessed(address indexed sender, uint256 count, uint256 totalAmount, address token)",
  "event RelayerWithdrawalProcessed(address indexed stealthAddress, address indexed to, address indexed relayer, address token, uint256 amount, uint256 relayerFee)",
];
