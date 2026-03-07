"use client";

import { useEffect, useState, useCallback } from "react";
import { ethers } from "ethers";
import { Cpu, CheckCircle2, XCircle, Zap, Hash, ShieldCheck, Activity } from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  StatCard, GlassCard, Badge, Button, Input, PageTransition, MonoBox, EmptyState,
} from "../components/ui";
import { getContracts, CONTRACT_ADDRESSES, CRYPTO_REGISTRY_ABI } from "../lib/contracts";
import { POLKADOT_HUB_TESTNET } from "../lib/stealth";

// ============================================================================
// Page
// ============================================================================

export default function PvmRegistryPage() {
  const { wallet } = useWalletContext();
  const [precompiles, setPrecompiles] = useState({
    sr25519: false, ed25519: false, blake2f: false, bn128: false,
  });
  const [loading, setLoading] = useState(true);

  // Blake2 hash tool
  const [hashInput, setHashInput] = useState("");
  const [hashResult, setHashResult] = useState("");
  const [hashing, setHashing] = useState(false);

  // Signature verification
  const [verifyType, setVerifyType] = useState<"sr25519" | "ed25519">("sr25519");
  const [verifyPubKey, setVerifyPubKey] = useState("");
  const [verifySignature, setVerifySignature] = useState("");
  const [verifyMessage, setVerifyMessage] = useState("");
  const [verifyResult, setVerifyResult] = useState<boolean | null>(null);
  const [verifying, setVerifying] = useState(false);

  // Stealth derivation verification
  const [stealthSpendKey, setStealthSpendKey] = useState("");
  const [stealthSecretHash, setStealthSecretHash] = useState("");
  const [stealthExpected, setStealthExpected] = useState("");
  const [stealthResult, setStealthResult] = useState<{ valid: boolean; computed: string } | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
        const c = getContracts(provider);
        const status = await c.cryptoRegistry.getPrecompileStatus();
        setPrecompiles({ sr25519: status[0], ed25519: status[1], blake2f: status[2], bn128: status[3] });
      } catch (e) { console.error("PVM fetch:", e); }
      setLoading(false);
    })();
  }, []);

  const handleHash = useCallback(async () => {
    setHashing(true);
    try {
      const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
      const reg = new ethers.Contract(CONTRACT_ADDRESSES.cryptoRegistry, CRYPTO_REGISTRY_ABI, provider);
      const data = ethers.toUtf8Bytes(hashInput);
      const result = await reg.blake2b256(data);
      setHashResult(result);
    } catch (e) { console.error("Hash failed:", e); setHashResult("Error: " + (e as Error).message); }
    setHashing(false);
  }, [hashInput]);

  const handleVerify = useCallback(async () => {
    setVerifying(true);
    setVerifyResult(null);
    try {
      const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
      const reg = new ethers.Contract(CONTRACT_ADDRESSES.cryptoRegistry, CRYPTO_REGISTRY_ABI, provider);
      const msg = ethers.toUtf8Bytes(verifyMessage);
      let result: boolean;
      if (verifyType === "sr25519") {
        result = await reg.verifySr25519Signature(verifyPubKey, verifySignature, msg);
      } else {
        // ed25519 requires R and S components
        const sigR = verifySignature.slice(0, 66);
        const sigS = "0x" + verifySignature.slice(66);
        result = await reg.verifyEd25519Signature(verifyPubKey, sigR, sigS, msg);
      }
      setVerifyResult(result);
    } catch (e) { console.error("Verify failed:", e); setVerifyResult(false); }
    setVerifying(false);
  }, [verifyType, verifyPubKey, verifySignature, verifyMessage]);

  const handleStealthVerify = useCallback(async () => {
    try {
      const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
      const reg = new ethers.Contract(CONTRACT_ADDRESSES.cryptoRegistry, CRYPTO_REGISTRY_ABI, provider);
      const [valid] = await Promise.all([
        reg.verifyStealthDerivation(stealthSpendKey, stealthSecretHash, stealthExpected),
      ]);
      const computed = await reg.computeStealthAddress(stealthSpendKey, stealthSecretHash);
      setStealthResult({ valid, computed });
    } catch (e) { console.error("Stealth verify:", e); }
  }, [stealthSpendKey, stealthSecretHash, stealthExpected]);

  const precompileList = [
    { name: "SR25519", desc: "Schnorr signatures (Substrate native)", key: "sr25519" as const, addr: "0x5002" },
    { name: "ED25519", desc: "Edwards curve signatures", key: "ed25519" as const, addr: "0x5003" },
    { name: "BLAKE2F", desc: "BLAKE2b-256 hashing (EIP-152)", key: "blake2f" as const, addr: "0x0009" },
    { name: "BN128", desc: "Alt-BN128 pairing (EIP-196/197)", key: "bn128" as const, addr: "0x0006-0x0008" },
  ];

  // Gas cost comparison (approximate values for context)
  const gasCosts = [
    { op: "BLAKE2b-256 (precompile)", gas: "~150", vs: "Keccak256: ~30", precompile: true },
    { op: "SR25519 verify (precompile)", gas: "~3,450", vs: "ECDSA recover: ~3,000", precompile: true },
    { op: "ED25519 verify (precompile)", gas: "~3,450", vs: "Not native to EVM", precompile: true },
    { op: "BN128 add (precompile)", gas: "~150", vs: "BN128 mul: ~6,000", precompile: true },
    { op: "Solidity BLAKE2 (emulated)", gas: "~50,000+", vs: "Precompile: ~150", precompile: false },
    { op: "Solidity SR25519 (N/A)", gas: "N/A", vs: "Only via precompile", precompile: false },
  ];

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">PVM & Crypto Registry</h1>
          <p className="mt-1 text-sm text-zinc-500">PVM precompile status, crypto primitives, and gas comparison</p>
        </div>

        {/* Precompile Status */}
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
          {precompileList.map((p) => (
            <StatCard
              key={p.key}
              label={p.name}
              value={loading ? "..." : precompiles[p.key] ? "Available" : "Unavailable"}
              icon={precompiles[p.key] ? <CheckCircle2 size={16} className="text-emerald-400" /> : <XCircle size={16} className="text-red-400" />}
              tooltip={`${p.desc} — Address: ${p.addr}`}
            />
          ))}
        </div>

        {/* Precompile Detail Cards */}
        <GlassCard title="Precompile Registry" icon={<Cpu size={18} className="text-indigo-400" />}>
          <div className="grid gap-3 sm:grid-cols-2">
            {precompileList.map((p) => (
              <div key={p.key} className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-4">
                <div className="flex items-center justify-between">
                  <h4 className="text-sm font-semibold text-zinc-200">{p.name}</h4>
                  <Badge variant={precompiles[p.key] ? "success" : "danger"}>
                    {precompiles[p.key] ? "Detected" : "Not Found"}
                  </Badge>
                </div>
                <p className="mt-1 text-xs text-zinc-500">{p.desc}</p>
                <p className="mt-2 font-mono text-[11px] text-zinc-600">Address: {p.addr}</p>
              </div>
            ))}
          </div>
        </GlassCard>

        <div className="grid gap-6 lg:grid-cols-2">
          {/* Blake2 Hash Tool */}
          <GlassCard title="BLAKE2b-256 Hasher" icon={<Hash size={18} className="text-purple-400" />}>
            <div className="space-y-3">
              <Input label="Input Data" value={hashInput} onChange={setHashInput} placeholder="Enter text to hash..." />
              <Button onClick={handleHash} disabled={!hashInput || hashing} variant="secondary">
                <Hash size={14} /> {hashing ? "Hashing..." : "Hash via PVM Precompile"}
              </Button>
              {hashResult && <MonoBox label="BLAKE2b-256 Result" value={hashResult} />}
            </div>
          </GlassCard>

          {/* Signature Verification */}
          <GlassCard title="Signature Verification" icon={<ShieldCheck size={18} className="text-emerald-400" />}>
            <div className="space-y-3">
              <div className="flex gap-2">
                {(["sr25519", "ed25519"] as const).map((t) => (
                  <button
                    key={t}
                    onClick={() => setVerifyType(t)}
                    className={`rounded-lg px-3 py-1.5 text-xs font-medium transition ${
                      verifyType === t ? "bg-indigo-600 text-white" : "bg-zinc-800 text-zinc-400 hover:bg-zinc-700"
                    }`}
                  >
                    {t.toUpperCase()}
                  </button>
                ))}
              </div>
              <Input label="Public Key (bytes32)" value={verifyPubKey} onChange={setVerifyPubKey} placeholder="0x..." />
              <Input label="Signature" value={verifySignature} onChange={setVerifySignature} placeholder="0x..." />
              <Input label="Message" value={verifyMessage} onChange={setVerifyMessage} placeholder="Hello, Polkadot!" />
              <Button onClick={handleVerify} disabled={!verifyPubKey || !verifySignature || !verifyMessage || verifying} variant="secondary">
                <ShieldCheck size={14} /> {verifying ? "Verifying..." : "Verify Signature"}
              </Button>
              {verifyResult !== null && (
                <div className={`rounded-lg border p-3 text-sm ${verifyResult ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-300" : "border-red-500/40 bg-red-500/10 text-red-300"}`}>
                  {verifyResult ? "✓ Signature is valid" : "✗ Signature is invalid"}
                </div>
              )}
            </div>
          </GlassCard>
        </div>

        {/* Stealth Address Derivation Verification */}
        <GlassCard title="Stealth Address Derivation" icon={<Activity size={18} className="text-amber-400" />}>
          <div className="grid gap-4 lg:grid-cols-2">
            <div className="space-y-3">
              <Input label="Spending Public Key (bytes32)" value={stealthSpendKey} onChange={setStealthSpendKey} placeholder="0x..." />
              <Input label="Shared Secret Hash (bytes32)" value={stealthSecretHash} onChange={setStealthSecretHash} placeholder="0x..." />
              <Input label="Expected Address" value={stealthExpected} onChange={setStealthExpected} placeholder="0x..." />
              <Button onClick={handleStealthVerify} disabled={!stealthSpendKey || !stealthSecretHash} variant="secondary">
                Verify Derivation
              </Button>
            </div>
            {stealthResult && (
              <div className="space-y-3">
                <div className={`rounded-lg border p-3 text-sm ${stealthResult.valid ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-300" : "border-red-500/40 bg-red-500/10 text-red-300"}`}>
                  {stealthResult.valid ? "✓ Derivation matches" : "✗ Derivation mismatch"}
                </div>
                <MonoBox label="Computed Stealth Address" value={stealthResult.computed} />
              </div>
            )}
          </div>
        </GlassCard>

        {/* Gas Comparison Table */}
        <GlassCard title="Gas Cost Comparison" icon={<Zap size={18} className="text-amber-400" />}>
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead>
                <tr className="border-b border-zinc-800 text-left">
                  <th className="px-4 py-3 text-xs font-medium uppercase tracking-wider text-zinc-500">Operation</th>
                  <th className="px-4 py-3 text-xs font-medium uppercase tracking-wider text-zinc-500">Gas Cost</th>
                  <th className="px-4 py-3 text-xs font-medium uppercase tracking-wider text-zinc-500">Comparison</th>
                  <th className="px-4 py-3 text-xs font-medium uppercase tracking-wider text-zinc-500">Type</th>
                </tr>
              </thead>
              <tbody>
                {gasCosts.map((g, i) => (
                  <tr key={i} className="border-b border-zinc-800/50">
                    <td className="px-4 py-3 text-sm text-zinc-300">{g.op}</td>
                    <td className="px-4 py-3 font-mono text-sm text-zinc-300">{g.gas}</td>
                    <td className="px-4 py-3 text-xs text-zinc-500">{g.vs}</td>
                    <td className="px-4 py-3">
                      <Badge variant={g.precompile ? "success" : "neutral"}>
                        {g.precompile ? "Precompile" : "Emulated"}
                      </Badge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </GlassCard>
      </div>
    </PageTransition>
  );
}
