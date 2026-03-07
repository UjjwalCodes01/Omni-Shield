"use client";

import { useEffect, useState, useCallback } from "react";
import { ethers } from "ethers";
import { Scale, AlertTriangle, FileText, CheckCircle2, XCircle, Send, Clock } from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  GlassCard, Badge, Button, Input, PageTransition,
  StatusStepper, DataTable, EmptyState, TxResult, MonoBox,
} from "../components/ui";
import {
  getContracts, CONTRACT_ADDRESSES, ESCROW_ABI,
  ESCROW_STATES,
} from "../lib/contracts";
import { POLKADOT_HUB_TESTNET } from "../lib/stealth";
import { useTx } from "../lib/hooks";

// ============================================================================
// Types
// ============================================================================

interface DisputeEscrow {
  id: number;
  depositor: string;
  recipient: string;
  amount: bigint;
  state: number;
  expiresAt: bigint;
  releaseConditionHash: string;
}

// ============================================================================
// Page
// ============================================================================

export default function DisputesPage() {
  const { wallet } = useWalletContext();
  const [disputedEscrows, setDisputedEscrows] = useState<DisputeEscrow[]>([]);
  const [loading, setLoading] = useState(true);

  // Raise dispute
  const [disputeEscrowId, setDisputeEscrowId] = useState("");
  const disputeTx = useTx();

  // Resolve dispute
  const [resolveEscrowId, setResolveEscrowId] = useState("");
  const [releaseToRecipient, setReleaseToRecipient] = useState(true);
  const resolveTx = useTx();

  // Evidence
  const [evidence, setEvidence] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
        const c = getContracts(provider);
        const count = await c.escrow.getEscrowCount().catch(() => BigInt(0));

        // Find disputed escrows
        const disputed: DisputeEscrow[] = [];
        const total = Number(count);
        for (let i = Math.max(0, total - 50); i < total; i++) {
          try {
            const e = await c.escrow.getEscrow(i);
            if (Number(e[5]) === 3) { // Disputed state
              disputed.push({
                id: i, depositor: e[0], recipient: e[1],
                amount: e[3], state: Number(e[5]),
                expiresAt: e[7], releaseConditionHash: e[8],
              });
            }
          } catch { /* skip */ }
        }
        setDisputedEscrows(disputed);
      } catch (e) { console.error("Dispute fetch:", e); }
      setLoading(false);
    })();
  }, []);

  const handleRaiseDispute = useCallback(async () => {
    if (!wallet.signer || !disputeEscrowId) return;
    const escrow = new ethers.Contract(CONTRACT_ADDRESSES.escrow, ESCROW_ABI, wallet.signer);
    await disputeTx.execute(() => escrow.dispute(parseInt(disputeEscrowId)));
  }, [wallet.signer, disputeEscrowId, disputeTx]);

  const handleResolve = useCallback(async () => {
    if (!wallet.signer || !resolveEscrowId) return;
    const escrow = new ethers.Contract(CONTRACT_ADDRESSES.escrow, ESCROW_ABI, wallet.signer);
    await resolveTx.execute(() => escrow.resolveDispute(parseInt(resolveEscrowId), releaseToRecipient));
  }, [wallet.signer, resolveEscrowId, releaseToRecipient, resolveTx]);

  const columns = [
    { header: "ID", accessor: (e: DisputeEscrow) => <span className="font-mono text-xs">#{e.id}</span> },
    {
      header: "Depositor",
      accessor: (e: DisputeEscrow) => <span className="font-mono text-xs">{e.depositor.slice(0, 8)}...{e.depositor.slice(-6)}</span>,
    },
    {
      header: "Recipient",
      accessor: (e: DisputeEscrow) => <span className="font-mono text-xs">{e.recipient.slice(0, 8)}...{e.recipient.slice(-6)}</span>,
    },
    { header: "Amount", accessor: (e: DisputeEscrow) => `${ethers.formatEther(e.amount)} WND` },
    { header: "Status", accessor: () => <Badge variant="danger">Disputed</Badge> },
    {
      header: "Condition",
      accessor: (e: DisputeEscrow) => (
        <span className="font-mono text-[11px] text-zinc-500">
          {e.releaseConditionHash === ethers.ZeroHash ? "None" : `${e.releaseConditionHash.slice(0, 10)}...`}
        </span>
      ),
    },
  ];

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">Dispute Resolution Portal</h1>
          <p className="mt-1 text-sm text-zinc-500">Raise, track, and resolve escrow disputes</p>
        </div>

        <div className="grid gap-6 lg:grid-cols-2">
          {/* Raise Dispute */}
          <GlassCard title="Raise Dispute" icon={<AlertTriangle size={18} className="text-red-400" />}>
            <StatusStepper steps={[
              { label: "Escrow ID", done: !!disputeEscrowId, active: !disputeEscrowId },
              { label: "Evidence", done: !!evidence, active: !!disputeEscrowId && !evidence },
              { label: "Submit", done: disputeTx.status.success, active: !!evidence },
            ]} />
            <div className="mt-4 space-y-3">
              <Input label="Escrow ID" value={disputeEscrowId} onChange={setDisputeEscrowId} placeholder="0" type="number" />
              <label className="block">
                <span className="mb-1 block text-sm text-zinc-400">Evidence / Reason</span>
                <textarea
                  value={evidence}
                  onChange={(e) => setEvidence(e.target.value)}
                  placeholder="Describe the dispute reason..."
                  rows={3}
                  className="w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-zinc-100 placeholder-zinc-600 transition focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500/30"
                />
              </label>
              <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3">
                <div className="flex items-start gap-2">
                  <AlertTriangle size={14} className="mt-0.5 text-amber-400" />
                  <div>
                    <p className="text-xs font-medium text-amber-400">Warning</p>
                    <p className="mt-0.5 text-[11px] text-zinc-500">
                      Filing a dispute will freeze the escrow. Only the escrow depositor or recipient can raise disputes.
                      Evidence is stored off-chain for now.
                    </p>
                  </div>
                </div>
              </div>
              <Button variant="danger" onClick={handleRaiseDispute} disabled={!wallet.connected || !disputeEscrowId || disputeTx.status.pending}>
                <AlertTriangle size={14} /> {disputeTx.status.pending ? "Submitting..." : "Raise Dispute"}
              </Button>
              <TxResult label="Dispute" {...disputeTx.status} />
            </div>
          </GlassCard>

          {/* Resolve Dispute */}
          <GlassCard title="Resolve Dispute" icon={<Scale size={18} className="text-emerald-400" />}>
            <StatusStepper steps={[
              { label: "Escrow ID", done: !!resolveEscrowId, active: !resolveEscrowId },
              { label: "Decision", done: true, active: !!resolveEscrowId },
              { label: "Execute", done: resolveTx.status.success, active: !!resolveEscrowId },
            ]} />
            <div className="mt-4 space-y-3">
              <Input label="Escrow ID" value={resolveEscrowId} onChange={setResolveEscrowId} placeholder="0" type="number" />
              <div>
                <span className="mb-2 block text-sm text-zinc-400">Resolution Decision</span>
                <div className="flex gap-3">
                  <button
                    onClick={() => setReleaseToRecipient(true)}
                    className={`flex-1 rounded-lg border p-3 text-center text-sm transition ${
                      releaseToRecipient ? "border-emerald-500 bg-emerald-500/10 text-emerald-400" : "border-zinc-700 bg-zinc-800/50 text-zinc-400 hover:border-zinc-600"
                    }`}
                  >
                    <CheckCircle2 size={16} className="mx-auto mb-1" />
                    Release to Recipient
                  </button>
                  <button
                    onClick={() => setReleaseToRecipient(false)}
                    className={`flex-1 rounded-lg border p-3 text-center text-sm transition ${
                      !releaseToRecipient ? "border-red-500 bg-red-500/10 text-red-400" : "border-zinc-700 bg-zinc-800/50 text-zinc-400 hover:border-zinc-600"
                    }`}
                  >
                    <XCircle size={16} className="mx-auto mb-1" />
                    Refund to Depositor
                  </button>
                </div>
              </div>
              <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
                <p className="text-xs text-zinc-500">
                  <span className="font-medium text-zinc-400">Note:</span> Only the contract owner (admin/timelock) can resolve disputes.
                  The decision is final and irreversible.
                </p>
              </div>
              <Button onClick={handleResolve} disabled={!wallet.connected || !resolveEscrowId || resolveTx.status.pending}>
                <Scale size={14} /> {resolveTx.status.pending ? "Resolving..." : "Execute Resolution"}
              </Button>
              <TxResult label="Resolution" {...resolveTx.status} />
            </div>
          </GlassCard>
        </div>

        {/* Disputed Escrows */}
        <GlassCard title="Active Disputes" icon={<Scale size={18} className="text-amber-400" />}>
          {loading ? (
            <p className="py-8 text-center text-sm text-zinc-500">Loading disputes...</p>
          ) : disputedEscrows.length === 0 ? (
            <EmptyState icon="⚖️" title="No active disputes" description="No escrows are currently in disputed state." />
          ) : (
            <DataTable columns={columns} data={disputedEscrows} />
          )}
        </GlassCard>

        {/* Dispute Flow Guide */}
        <GlassCard title="Dispute Process" icon={<FileText size={18} className="text-indigo-400" />}>
          <div className="grid gap-4 sm:grid-cols-4">
            {[
              { step: 1, title: "Raise", desc: "Either party calls dispute() on the escrow", icon: <AlertTriangle size={20} className="text-red-400" /> },
              { step: 2, title: "Evidence", desc: "Both parties provide evidence off-chain", icon: <FileText size={20} className="text-amber-400" /> },
              { step: 3, title: "Review", desc: "Admin reviews evidence and conditions", icon: <Scale size={20} className="text-indigo-400" /> },
              { step: 4, title: "Resolve", desc: "Admin calls resolveDispute() with decision", icon: <CheckCircle2 size={20} className="text-emerald-400" /> },
            ].map((s) => (
              <div key={s.step} className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-4 text-center">
                <div className="mx-auto mb-2 flex h-10 w-10 items-center justify-center rounded-full bg-zinc-800">
                  {s.icon}
                </div>
                <p className="text-xs font-medium text-zinc-300">Step {s.step}: {s.title}</p>
                <p className="mt-1 text-[11px] text-zinc-500">{s.desc}</p>
              </div>
            ))}
          </div>
        </GlassCard>
      </div>
    </PageTransition>
  );
}
