"use client";

import { useState, useCallback } from "react";
import { ethers } from "ethers";
import { motion, AnimatePresence } from "framer-motion";
import { Search, Radio, Eye, Clock, CheckCircle2, Zap } from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  GlassCard, Badge, Button, Input, PageTransition, MonoBox,
  StatusStepper, EmptyState, DataTable,
} from "../components/ui";
import { CONTRACT_ADDRESSES } from "../lib/contracts";
import {
  POLKADOT_HUB_TESTNET, STEALTH_PAYMENT_ABI,
  scanForPayments, type ScannedPayment,
  generateStealthKeyPair, type StealthKeyPair,
} from "../lib/stealth";

// ============================================================================
// Page
// ============================================================================

export default function StealthScannerPage() {
  const { wallet } = useWalletContext();

  // Key input
  const [viewingPrivKey, setViewingPrivKey] = useState("");
  const [spendingPubKey, setSpendingPubKey] = useState("");
  const [fromBlock, setFromBlock] = useState("0");
  const [toBlock, setToBlock] = useState("");

  // Scan state
  const [scanning, setScanning] = useState(false);
  const [results, setResults] = useState<ScannedPayment[]>([]);
  const [scanProgress, setScanProgress] = useState(0);
  const [scannedBlocks, setScannedBlocks] = useState(0);
  const [totalAnnouncements, setTotalAnnouncements] = useState(0);

  // Quick generate keys
  const [quickKeys, setQuickKeys] = useState<StealthKeyPair | null>(null);

  const handleGenerateAndFill = useCallback(() => {
    const kp = generateStealthKeyPair();
    setQuickKeys(kp);
    setViewingPrivKey(kp.viewingPrivateKey);
    setSpendingPubKey(kp.metaAddress.spendingPubKey);
  }, []);

  const handleScan = useCallback(async () => {
    if (!wallet.provider || !viewingPrivKey || !spendingPubKey) return;
    setScanning(true);
    setResults([]);
    setScanProgress(0);

    try {
      // Get total announcement count first
      const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
      const sp = new ethers.Contract(CONTRACT_ADDRESSES.stealthPayment, STEALTH_PAYMENT_ABI, provider);
      let annCount = 0;
      try { annCount = Number(await sp.getAnnouncementCount()); } catch { /* skip */ }
      setTotalAnnouncements(annCount);

      const from = parseInt(fromBlock) || 0;
      const found = await scanForPayments(
        provider,
        CONTRACT_ADDRESSES.stealthPayment,
        viewingPrivKey,
        spendingPubKey,
        from,
      );
      setResults(found);
      setScanProgress(100);
      setScannedBlocks(annCount);
    } catch (e) {
      console.error("Scan failed:", e);
    }
    setScanning(false);
  }, [wallet.provider, viewingPrivKey, spendingPubKey, fromBlock]);

  const columns = [
    { header: "#", accessor: (p: ScannedPayment) => <span className="font-mono text-xs">{results.indexOf(p) + 1}</span> },
    {
      header: "Stealth Address",
      accessor: (p: ScannedPayment) => (
        <a
          href={`https://blockscout-testnet.polkadot.io/address/${p.stealthAddress}`}
          target="_blank" rel="noopener noreferrer"
          className="font-mono text-xs text-indigo-400 hover:underline"
        >
          {p.stealthAddress.slice(0, 10)}...{p.stealthAddress.slice(-8)}
        </a>
      ),
    },
    { header: "Block", accessor: (p: ScannedPayment) => <span className="font-mono text-xs">{p.blockNumber}</span> },
    { header: "View Tag", accessor: (p: ScannedPayment) => <Badge variant="info">{p.viewTag}</Badge> },
    {
      header: "Ephemeral Key",
      accessor: (p: ScannedPayment) => (
        <span className="font-mono text-[11px] text-zinc-500">{p.ephemeralPubKey.slice(0, 14)}...</span>
      ),
    },
  ];

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">Stealth Scanner</h1>
          <p className="mt-1 text-sm text-zinc-500">Scan blockchain for stealth payments destined to your meta-address</p>
        </div>

        {/* Scanner */}
        <GlassCard title="Scanner Configuration" icon={<Search size={18} className="text-indigo-400" />}>
          <StatusStepper steps={[
            { label: "Keys", done: !!viewingPrivKey && !!spendingPubKey, active: !viewingPrivKey },
            { label: "Block Range", done: !!fromBlock, active: !!viewingPrivKey && !fromBlock },
            { label: "Scan", done: results.length > 0, active: !!fromBlock && !scanning },
          ]} />

          <div className="mt-4 grid gap-4 lg:grid-cols-2">
            <div className="space-y-3">
              <Input label="Viewing Private Key" value={viewingPrivKey} onChange={setViewingPrivKey} placeholder="0x..." />
              <Input label="Spending Public Key" value={spendingPubKey} onChange={setSpendingPubKey} placeholder="0x..." />
              <Button variant="ghost" size="sm" onClick={handleGenerateAndFill}>
                <Zap size={12} /> Generate test keys & fill
              </Button>
            </div>
            <div className="space-y-3">
              <Input label="From Block" value={fromBlock} onChange={setFromBlock} placeholder="0" type="number" />
              <Input label="To Block (latest if empty)" value={toBlock} onChange={setToBlock} placeholder="latest" type="number" />
              <Button onClick={handleScan} disabled={!viewingPrivKey || !spendingPubKey || scanning}>
                <Search size={14} /> {scanning ? "Scanning..." : "Scan Blockchain"}
              </Button>
            </div>
          </div>
        </GlassCard>

        {/* Radar Animation */}
        <AnimatePresence>
          {scanning && (
            <motion.div
              initial={{ opacity: 0, scale: 0.95 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0, scale: 0.95 }}
              className="flex flex-col items-center py-12"
            >
              <div className="relative h-32 w-32">
                <motion.div
                  animate={{ rotate: 360 }}
                  transition={{ duration: 2, repeat: Infinity, ease: "linear" }}
                  className="absolute inset-0 rounded-full border-2 border-indigo-500/30"
                >
                  <div className="absolute left-1/2 top-0 h-1/2 w-px bg-gradient-to-b from-indigo-500 to-transparent" />
                </motion.div>
                <div className="absolute inset-4 rounded-full border border-indigo-500/20" />
                <div className="absolute inset-8 rounded-full border border-indigo-500/10" />
                <div className="absolute inset-0 flex items-center justify-center">
                  <Radio size={24} className="text-indigo-400" />
                </div>
              </div>
              <p className="mt-4 text-sm text-zinc-400">Scanning announcements...</p>
              <p className="mt-1 text-xs text-zinc-600">Checking {totalAnnouncements} on-chain announcements</p>
            </motion.div>
          )}
        </AnimatePresence>

        {/* Results */}
        {!scanning && results.length > 0 && (
          <GlassCard title={`Found ${results.length} Payment(s)`} icon={<CheckCircle2 size={18} className="text-emerald-400" />}>
            <div className="mb-4 flex items-center gap-4 text-xs text-zinc-500">
              <span className="flex items-center gap-1"><Clock size={12} /> Scanned {scannedBlocks} announcements</span>
              <span className="flex items-center gap-1"><Eye size={12} /> {results.length} matched your viewing key</span>
            </div>
            <DataTable columns={columns} data={results} />

            {/* Payment details */}
            <div className="mt-4 space-y-3">
              {results.map((r, i) => (
                <div key={i} className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-4">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium text-zinc-200">Payment #{i + 1}</span>
                    <Badge variant="success">Matched</Badge>
                  </div>
                  <MonoBox label="Stealth Address" value={r.stealthAddress} />
                  <MonoBox label="Ephemeral Public Key" value={r.ephemeralPubKey} />
                  <div className="mt-2 grid grid-cols-2 gap-4">
                    <div>
                      <p className="text-xs text-zinc-500">Block Number</p>
                      <p className="font-mono text-sm text-zinc-300">{r.blockNumber}</p>
                    </div>
                    <div>
                      <p className="text-xs text-zinc-500">View Tag</p>
                      <p className="font-mono text-sm text-zinc-300">{r.viewTag}</p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </GlassCard>
        )}

        {!scanning && results.length === 0 && scanProgress > 0 && (
          <EmptyState icon="🔍" title="No payments found" description="No stealth payments match your viewing key in the specified block range." />
        )}
      </div>
    </PageTransition>
  );
}
