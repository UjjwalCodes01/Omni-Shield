"use client";

import { useState, useCallback, useRef } from "react";
import { ethers } from "ethers";
import { Users, Upload, Send, FileText, CheckCircle2, AlertTriangle, Trash2 } from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  GlassCard, Badge, Button, Input, PageTransition,
  StatusStepper, DataTable, EmptyState, TxResult,
} from "../components/ui";
import { CONTRACT_ADDRESSES } from "../lib/contracts";
import {
  STEALTH_PAYMENT_ABI, computeStealthPayment,
} from "../lib/stealth";
import { useTx } from "../lib/hooks";

// ============================================================================
// Types
// ============================================================================

interface PayrollEntry {
  id: number;
  name: string;
  spendingPubKey: string;
  viewingPubKey: string;
  amount: string;
  status: "pending" | "sending" | "success" | "failed";
  txHash?: string;
  error?: string;
}

// ============================================================================
// Page
// ============================================================================

export default function B2BPayrollPage() {
  const { wallet } = useWalletContext();
  const [entries, setEntries] = useState<PayrollEntry[]>([]);
  const [processing, setProcessing] = useState(false);
  const [completedCount, setCompletedCount] = useState(0);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Manual entry form
  const [name, setName] = useState("");
  const [spendKey, setSpendKey] = useState("");
  const [viewKey, setViewKey] = useState("");
  const [amount, setAmount] = useState("");

  const nextId = useCallback(() => {
    return entries.length > 0 ? Math.max(...entries.map((e) => e.id)) + 1 : 1;
  }, [entries]);

  const addEntry = useCallback(() => {
    if (!name || !spendKey || !viewKey || !amount) return;
    setEntries((prev) => [
      ...prev,
      { id: nextId(), name, spendingPubKey: spendKey, viewingPubKey: viewKey, amount, status: "pending" },
    ]);
    setName(""); setSpendKey(""); setViewKey(""); setAmount("");
  }, [name, spendKey, viewKey, amount, nextId]);

  const removeEntry = useCallback((id: number) => {
    setEntries((prev) => prev.filter((e) => e.id !== id));
  }, []);

  const handleCSVUpload = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (event) => {
      const text = event.target?.result as string;
      const lines = text.trim().split("\n").slice(1); // Skip header
      const newEntries: PayrollEntry[] = lines.map((line, i) => {
        const [csvName, spend, view, amt] = line.split(",").map((s) => s.trim());
        return {
          id: nextId() + i,
          name: csvName || `Employee ${i + 1}`,
          spendingPubKey: spend || "",
          viewingPubKey: view || "",
          amount: amt || "0",
          status: "pending" as const,
        };
      }).filter((e) => e.spendingPubKey && e.viewingPubKey);
      setEntries((prev) => [...prev, ...newEntries]);
    };
    reader.readAsText(file);
    if (fileInputRef.current) fileInputRef.current.value = "";
  }, [nextId]);

  const handleBatchSend = useCallback(async () => {
    if (!wallet.signer || entries.length === 0) return;
    setProcessing(true);
    setCompletedCount(0);

    const sp = new ethers.Contract(CONTRACT_ADDRESSES.stealthPayment, STEALTH_PAYMENT_ABI, wallet.signer);

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (entry.status === "success") { setCompletedCount((c) => c + 1); continue; }

      setEntries((prev) => prev.map((e) => e.id === entry.id ? { ...e, status: "sending" } : e));
      try {
        const payment = computeStealthPayment({
          spendingPubKey: entry.spendingPubKey,
          viewingPubKey: entry.viewingPubKey,
        });
        const tx = await sp.sendNativeToStealth(
          payment.stealthAddress,
          payment.ephemeralPubKey,
          payment.viewTag,
          "0x",
          { value: ethers.parseEther(entry.amount) }
        );
        await tx.wait();
        setEntries((prev) => prev.map((e) => e.id === entry.id ? { ...e, status: "success", txHash: tx.hash } : e));
      } catch (err) {
        const msg = err instanceof Error ? err.message : "Failed";
        setEntries((prev) => prev.map((e) => e.id === entry.id ? { ...e, status: "failed", error: msg } : e));
      }
      setCompletedCount((c) => c + 1);
    }
    setProcessing(false);
  }, [wallet.signer, entries]);

  const totalAmount = entries.reduce((sum, e) => sum + parseFloat(e.amount || "0"), 0);
  const successCount = entries.filter((e) => e.status === "success").length;
  const failedCount = entries.filter((e) => e.status === "failed").length;

  const columns = [
    { header: "#", accessor: (e: PayrollEntry) => <span className="font-mono text-xs">{e.id}</span> },
    { header: "Name", accessor: (e: PayrollEntry) => <span className="text-sm text-zinc-200">{e.name}</span> },
    {
      header: "Spending Key",
      accessor: (e: PayrollEntry) => <span className="font-mono text-[11px] text-zinc-500">{e.spendingPubKey.slice(0, 12)}...</span>,
    },
    { header: "Amount", accessor: (e: PayrollEntry) => `${e.amount} WND` },
    {
      header: "Status",
      accessor: (e: PayrollEntry) => {
        const variants: Record<string, "neutral" | "warning" | "success" | "danger"> = {
          pending: "neutral", sending: "warning", success: "success", failed: "danger",
        };
        return <Badge variant={variants[e.status]}>{e.status}</Badge>;
      },
    },
    {
      header: "Tx",
      accessor: (e: PayrollEntry) =>
        e.txHash ? (
          <a href={`https://blockscout-testnet.polkadot.io/tx/${e.txHash}`} target="_blank" rel="noopener noreferrer" className="font-mono text-[11px] text-indigo-400 hover:underline">
            {e.txHash.slice(0, 10)}...
          </a>
        ) : e.error ? (
          <span className="text-[11px] text-red-400 truncate max-w-[120px] inline-block">{e.error.slice(0, 30)}...</span>
        ) : "—",
    },
    {
      header: "",
      accessor: (e: PayrollEntry) =>
        e.status === "pending" ? (
          <button onClick={() => removeEntry(e.id)} className="text-zinc-500 hover:text-red-400 transition">
            <Trash2 size={14} />
          </button>
        ) : null,
    },
  ];

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">B2B Payroll & Batching</h1>
          <p className="mt-1 text-sm text-zinc-500">Batch stealth payments for private payroll — upload CSV or add manually</p>
        </div>

        <div className="grid gap-6 lg:grid-cols-3">
          {/* Add Entry */}
          <GlassCard title="Add Recipient" icon={<Users size={18} className="text-indigo-400" />}>
            <div className="space-y-3">
              <Input label="Name / Label" value={name} onChange={setName} placeholder="Alice" />
              <Input label="Spending Public Key" value={spendKey} onChange={setSpendKey} placeholder="0x..." />
              <Input label="Viewing Public Key" value={viewKey} onChange={setViewKey} placeholder="0x..." />
              <Input label="Amount (WND)" value={amount} onChange={setAmount} placeholder="0.01" type="number" />
              <Button variant="secondary" onClick={addEntry} disabled={!name || !spendKey || !viewKey || !amount}>
                <Users size={14} /> Add to Batch
              </Button>
            </div>

            <div className="mt-4 border-t border-zinc-800 pt-4">
              <p className="mb-2 text-xs font-medium text-zinc-400">Or upload CSV</p>
              <p className="mb-2 text-[10px] text-zinc-600">Format: name, spendingPubKey, viewingPubKey, amount</p>
              <input
                ref={fileInputRef}
                type="file"
                accept=".csv"
                onChange={handleCSVUpload}
                className="hidden"
              />
              <Button variant="ghost" size="sm" onClick={() => fileInputRef.current?.click()}>
                <Upload size={14} /> Upload CSV
              </Button>
            </div>
          </GlassCard>

          {/* Batch Summary & Execution */}
          <GlassCard title="Batch Summary" icon={<FileText size={18} className="text-emerald-400" />} className="lg:col-span-2">
            <StatusStepper steps={[
              { label: "Add Recipients", done: entries.length > 0, active: entries.length === 0 },
              { label: "Review", done: entries.length > 0 && !processing, active: entries.length > 0 && !processing },
              { label: "Processing", done: successCount === entries.length && entries.length > 0, active: processing },
              { label: "Complete", done: successCount === entries.length && entries.length > 0, active: false },
            ]} />

            <div className="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-4">
              <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
                <p className="text-xs text-zinc-500">Recipients</p>
                <p className="text-lg font-bold text-zinc-100">{entries.length}</p>
              </div>
              <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
                <p className="text-xs text-zinc-500">Total Amount</p>
                <p className="text-lg font-bold text-zinc-100">{totalAmount.toFixed(4)} WND</p>
              </div>
              <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
                <p className="text-xs text-zinc-500">Sent</p>
                <p className="text-lg font-bold text-emerald-400">{successCount}</p>
              </div>
              <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
                <p className="text-xs text-zinc-500">Failed</p>
                <p className="text-lg font-bold text-red-400">{failedCount}</p>
              </div>
            </div>

            <div className="mt-4 flex gap-3">
              <Button onClick={handleBatchSend} disabled={!wallet.connected || entries.length === 0 || processing}>
                <Send size={14} /> {processing ? `Sending ${completedCount}/${entries.length}...` : "Execute Batch"}
              </Button>
              {entries.length > 0 && !processing && (
                <Button variant="danger" onClick={() => setEntries([])}>
                  <Trash2 size={14} /> Clear All
                </Button>
              )}
            </div>

            {processing && (
              <div className="mt-4">
                <div className="h-2 overflow-hidden rounded-full bg-zinc-800">
                  <div
                    className="h-full rounded-full bg-indigo-500 transition-all duration-500"
                    style={{ width: `${entries.length > 0 ? (completedCount / entries.length) * 100 : 0}%` }}
                  />
                </div>
                <p className="mt-1 text-xs text-zinc-500">{completedCount} of {entries.length} payments processed</p>
              </div>
            )}
          </GlassCard>
        </div>

        {/* Payment Table */}
        <GlassCard title="Payment Queue" icon={<Users size={18} className="text-amber-400" />}>
          {entries.length === 0 ? (
            <EmptyState icon="📋" title="No recipients" description="Add recipients manually or upload a CSV file." />
          ) : (
            <DataTable columns={columns} data={entries} />
          )}
        </GlassCard>
      </div>
    </PageTransition>
  );
}
