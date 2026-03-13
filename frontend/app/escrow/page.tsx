"use client";

import { useEffect, useState, useCallback } from "react";
import { ethers } from "ethers";
import {
  Lock, Plus, ArrowUpFromLine, AlertTriangle,
  CheckCircle2, Clock, Filter, ExternalLink,
} from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  StatCard, GlassCard, Badge, Button, Input, PageTransition,
  StatusStepper, DataTable, EmptyState, TxResult,
} from "../components/ui";
import {
  getContracts, CONTRACT_ADDRESSES, ESCROW_ABI,
  ESCROW_STATES, type EscrowStateName,
} from "../lib/contracts";
import { POLKADOT_HUB_TESTNET } from "../lib/stealth";
import { useTx } from "../lib/hooks";

// ============================================================================
// Types
// ============================================================================

interface EscrowData {
  id: number;
  depositor: string;
  recipient: string;
  token: string;
  amount: bigint;
  fee: bigint;
  state: number;
  createdAt: bigint;
  expiresAt: bigint;
  releaseConditionHash: string;
}

type TabFilter = "all" | "incoming" | "outgoing" | "disputed";

// ============================================================================
// Page
// ============================================================================

export default function EscrowCenterPage() {
  const { wallet } = useWalletContext();
  const [escrows, setEscrows] = useState<EscrowData[]>([]);
  const [escrowCount, setEscrowCount] = useState("0");
  const [totalActive, setTotalActive] = useState("0");
  const [feeBps, setFeeBps] = useState("0");
  const [filter, setFilter] = useState<TabFilter>("all");

  // Create escrow form
  const [recipient, setRecipient] = useState("");
  const [amount, setAmount] = useState("");
  const [expiresIn, setExpiresIn] = useState("3600");
  const [conditionHash, setConditionHash] = useState("");
  const createTx = useTx();

  // Release/Refund
  const [releaseId, setReleaseId] = useState("");
  const [conditionData, setConditionData] = useState("");
  const releaseTx = useTx();
  const refundTx = useTx();

  // Fetch data
  useEffect(() => {
    (async () => {
      try {
        const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
        const c = getContracts(provider);
        const [count, active, fee] = await Promise.all([
          c.escrow.getEscrowCount().catch(() => BigInt(0)),
          c.escrow.totalActiveEscrowAmount(ethers.ZeroAddress).catch(() => BigInt(0)),
          c.escrow.protocolFeeBps().catch(() => BigInt(0)),
        ]);
        setEscrowCount(count.toString());
        setTotalActive(ethers.formatEther(active));
        setFeeBps(fee.toString());

        // Load escrows for current user
        if (wallet.address) {
          const [depIds, recIds] = await Promise.all([
            c.escrow.getDepositorEscrows(wallet.address).catch(() => []),
            c.escrow.getRecipientEscrows(wallet.address).catch(() => []),
          ]);
          const allIds = [...new Set([...depIds.map(Number), ...recIds.map(Number)])];
          const escArr: EscrowData[] = [];
          for (const id of allIds) {
            try {
              const e = await c.escrow.getEscrow(id);
              escArr.push({
                id, depositor: e[0], recipient: e[1], token: e[2],
                amount: e[3], fee: e[4], state: Number(e[5]),
                createdAt: e[6], expiresAt: e[7], releaseConditionHash: e[8],
              });
            } catch { /* skip */ }
          }
          setEscrows(escArr.sort((a, b) => b.id - a.id));
        }
      } catch (e) { console.error("Escrow fetch:", e); }
    })();
  }, [wallet.address]);

  // Handlers
  const handleCreate = useCallback(async () => {
    if (!wallet.signer || !recipient || !amount) return;

    if (!ethers.isAddress(recipient)) {
      createTx.fail("Recipient must be a valid address.");
      return;
    }

    if (recipient.toLowerCase() === wallet.address.toLowerCase()) {
      createTx.fail("Recipient cannot be your own address.");
      return;
    }

    let amountWei: bigint;
    try {
      amountWei = ethers.parseEther(amount);
    } catch {
      createTx.fail("Invalid escrow amount.");
      return;
    }

    if (amountWei <= BigInt(0)) {
      createTx.fail("Escrow amount must be greater than zero.");
      return;
    }

    const expiresInSec = parseInt(expiresIn || "0");
    if (!Number.isFinite(expiresInSec) || expiresInSec < 3600) {
      createTx.fail("Expiry must be at least 3600 seconds (1 hour).");
      return;
    }
    if (expiresInSec > 365 * 24 * 3600) {
      createTx.fail("Expiry cannot exceed 365 days.");
      return;
    }

    const escrow = new ethers.Contract(CONTRACT_ADDRESSES.escrow, ESCROW_ABI, wallet.signer);
    const expiresAt = Math.floor(Date.now() / 1000) + expiresInSec;
    const hash = conditionHash || ethers.ZeroHash;
    await createTx.execute(() =>
      escrow.createEscrowNative(recipient, expiresAt, hash, { value: amountWei })
    );
  }, [wallet.signer, wallet.address, recipient, amount, expiresIn, conditionHash, createTx]);

  const handleRelease = useCallback(async () => {
    if (!wallet.signer || !releaseId) return;
    const escrow = new ethers.Contract(CONTRACT_ADDRESSES.escrow, ESCROW_ABI, wallet.signer);

    const id = parseInt(releaseId, 10);
    if (!Number.isFinite(id) || id < 0) {
      releaseTx.fail("Escrow ID must be a non-negative number.");
      return;
    }

    try {
      const entry = await escrow.getEscrow(id);
      const state = Number(entry[5]);
      const depositor = String(entry[0]).toLowerCase();
      const releaseConditionHash = String(entry[8]);

      if (state !== 0) {
        releaseTx.fail("Escrow is not active.");
        return;
      }
      if (depositor !== wallet.address.toLowerCase()) {
        releaseTx.fail("Only the escrow depositor can release.");
        return;
      }
      if (releaseConditionHash !== ethers.ZeroHash && !conditionData) {
        releaseTx.fail("Condition data is required for this escrow release.");
        return;
      }
    } catch {
      releaseTx.fail("Unable to load escrow details for this ID.");
      return;
    }

    await releaseTx.execute(() => escrow.release(id, conditionData || "0x"));
  }, [wallet.signer, wallet.address, releaseId, conditionData, releaseTx]);

  const handleRefund = useCallback(async () => {
    if (!wallet.signer || !releaseId) return;
    const escrow = new ethers.Contract(CONTRACT_ADDRESSES.escrow, ESCROW_ABI, wallet.signer);
    const id = parseInt(releaseId, 10);
    if (!Number.isFinite(id) || id < 0) {
      refundTx.fail("Escrow ID must be a non-negative number.");
      return;
    }
    await refundTx.execute(() => escrow.refund(id));
  }, [wallet.signer, releaseId, refundTx]);

  // Filter
  const filtered = escrows.filter((e) => {
    if (filter === "incoming") return e.recipient.toLowerCase() === wallet.address.toLowerCase();
    if (filter === "outgoing") return e.depositor.toLowerCase() === wallet.address.toLowerCase();
    if (filter === "disputed") return e.state === 3;
    return true;
  });

  const stateVariant = (s: number): "success" | "warning" | "danger" | "info" | "neutral" => {
    if (s === 0) return "info";     // Active
    if (s === 1) return "success";  // Released
    if (s === 2) return "neutral";  // Refunded
    if (s === 3) return "danger";   // Disputed
    return "warning";               // Expired
  };

  const columns = [
    { header: "ID", accessor: (e: EscrowData) => <span className="font-mono text-xs">#{e.id}</span> },
    {
      header: "Direction",
      accessor: (e: EscrowData) => {
        const isDepositor = e.depositor.toLowerCase() === wallet.address.toLowerCase();
        return <Badge variant={isDepositor ? "warning" : "info"}>{isDepositor ? "Outgoing" : "Incoming"}</Badge>;
      },
    },
    { header: "Amount", accessor: (e: EscrowData) => `${ethers.formatEther(e.amount)} WND` },
    {
      header: "Counterparty",
      accessor: (e: EscrowData) => {
        const addr = e.depositor.toLowerCase() === wallet.address.toLowerCase() ? e.recipient : e.depositor;
        return <span className="font-mono text-xs">{addr.slice(0, 8)}...{addr.slice(-6)}</span>;
      },
    },
    {
      header: "Status",
      accessor: (e: EscrowData) => <Badge variant={stateVariant(e.state)}>{ESCROW_STATES[e.state]}</Badge>,
    },
    {
      header: "Expires",
      accessor: (e: EscrowData) => {
        const d = new Date(Number(e.expiresAt) * 1000);
        return <span className="text-xs text-zinc-500">{d.toLocaleString()}</span>;
      },
    },
    {
      header: "",
      accessor: (e: EscrowData) => (
        <a
          href={`https://blockscout-testnet.polkadot.io/address/${CONTRACT_ADDRESSES.escrow}`}
          target="_blank" rel="noopener noreferrer"
          className="text-zinc-500 hover:text-zinc-300 transition"
        >
          <ExternalLink size={14} />
        </a>
      ),
    },
  ];

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">Escrow Command Center</h1>
          <p className="mt-1 text-sm text-zinc-500">Create, manage, release, and refund escrow contracts</p>
        </div>

        {/* Stats */}
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <StatCard label="Total Escrows" value={escrowCount} icon={<Lock size={16} />} tooltip="All escrows ever created" />
          <StatCard label="Active Amount" value={`${parseFloat(totalActive).toFixed(4)} WND`} icon={<Clock size={16} />} tooltip="Native token locked in active escrows" />
          <StatCard label="Protocol Fee" value={`${parseInt(feeBps) / 100}%`} icon={<AlertTriangle size={16} />} tooltip="Fee charged on escrow release" />
          <StatCard label="Your Escrows" value={escrows.length.toString()} icon={<CheckCircle2 size={16} />} tooltip="Escrows involving your address" />
        </div>

        <div className="grid gap-6 lg:grid-cols-3">
          {/* Create Escrow */}
          <GlassCard title="Create Escrow" icon={<Plus size={18} className="text-indigo-400" />}>
            <StatusStepper steps={[
              { label: "Recipient", done: !!recipient, active: !recipient },
              { label: "Amount", done: !!amount, active: !!recipient && !amount },
              { label: "Confirm", done: createTx.status.success, active: !!amount },
            ]} />
            <div className="mt-4 space-y-3">
              <Input label="Recipient Address" value={recipient} onChange={setRecipient} placeholder="0x..." />
              <Input label="Amount (WND)" value={amount} onChange={setAmount} placeholder="0.1" type="number" />
              <Input label="Expires In (seconds)" value={expiresIn} onChange={setExpiresIn} placeholder="3600" type="number" />
              <Input label="Condition Hash (optional)" value={conditionHash} onChange={setConditionHash} placeholder="0x... or leave empty" />
              <Button onClick={handleCreate} disabled={!wallet.connected || !recipient || !amount || createTx.status.pending}>
                <Plus size={14} /> {createTx.status.pending ? "Creating..." : "Create Escrow"}
              </Button>
              <TxResult label="Create" {...createTx.status} />
            </div>
          </GlassCard>

          {/* Release / Refund */}
          <GlassCard title="Release / Refund" icon={<ArrowUpFromLine size={18} className="text-emerald-400" />} className="lg:col-span-2">
            <div className="space-y-3">
              <Input label="Escrow ID" value={releaseId} onChange={setReleaseId} placeholder="0" type="number" />
              <Input label="Condition Data (for release)" value={conditionData} onChange={setConditionData} placeholder="0x... (leave empty for no condition)" />
              <div className="flex gap-3">
                <Button onClick={handleRelease} disabled={!wallet.connected || !releaseId || releaseTx.status.pending}>
                  <CheckCircle2 size={14} /> {releaseTx.status.pending ? "Releasing..." : "Release"}
                </Button>
                <Button variant="danger" onClick={handleRefund} disabled={!wallet.connected || !releaseId || refundTx.status.pending}>
                  <ArrowUpFromLine size={14} /> {refundTx.status.pending ? "Refunding..." : "Refund"}
                </Button>
              </div>
              <TxResult label="Release" {...releaseTx.status} />
              <TxResult label="Refund" {...refundTx.status} />
            </div>
          </GlassCard>
        </div>

        {/* Escrow Table */}
        <GlassCard title="Your Escrows" icon={<Lock size={18} className="text-amber-400" />}>
          <div className="mb-4 flex gap-2">
            {(["all", "incoming", "outgoing", "disputed"] as TabFilter[]).map((f) => (
              <button
                key={f}
                onClick={() => setFilter(f)}
                className={`rounded-lg px-3 py-1.5 text-xs font-medium transition ${
                  filter === f ? "bg-indigo-600 text-white" : "bg-zinc-800 text-zinc-400 hover:bg-zinc-700"
                }`}
              >
                <Filter size={10} className="mr-1 inline" />
                {f.charAt(0).toUpperCase() + f.slice(1)}
              </button>
            ))}
          </div>
          {filtered.length === 0 ? (
            <EmptyState icon="📜" title="No escrows found" description="Create an escrow or wait for incoming ones." />
          ) : (
            <DataTable columns={columns} data={filtered} />
          )}
        </GlassCard>
      </div>
    </PageTransition>
  );
}
