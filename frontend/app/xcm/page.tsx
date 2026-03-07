"use client";

import { useEffect, useState } from "react";
import { ethers } from "ethers";
import {
  PieChart, Pie, Cell, ResponsiveContainer, Tooltip as RTooltip,
} from "recharts";
import {
  Globe, ArrowRight, Clock, CheckCircle2,
  AlertTriangle, Zap, Radio,
} from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  StatCard, GlassCard, Badge, PageTransition,
  DataTable, EmptyState, PulseDot,
} from "../components/ui";
import {
  getContracts, PARACHAINS, CONTRACT_ADDRESSES,
  XCM_STATUSES, type XcmStatusName,
} from "../lib/contracts";
import { POLKADOT_HUB_TESTNET } from "../lib/stealth";

// ============================================================================
// Types
// ============================================================================

interface DispatchData {
  id: number;
  routeId: number;
  paraId: number;
  amount: bigint;
  status: number;
  xcmMessageHash: string;
  dispatchedAt: bigint;
  confirmedAt: bigint;
  timeoutAt: bigint;
}

// ============================================================================
// Page
// ============================================================================

export default function XcmExplorerPage() {
  const { wallet } = useWalletContext();
  const [dispatches, setDispatches] = useState<DispatchData[]>([]);
  const [dispatchCount, setDispatchCount] = useState("0");
  const [pending, setPending] = useState("0");
  const [inTransit, setInTransit] = useState("0");
  const [xcmAvailable, setXcmAvailable] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
        const c = getContracts(provider);
        const [count, pend, transit, avail] = await Promise.all([
          c.xcmRouter.getDispatchCount().catch(() => BigInt(0)),
          c.xcmRouter.pendingDispatches().catch(() => BigInt(0)),
          c.xcmRouter.amountInTransit().catch(() => BigInt(0)),
          c.xcmRouter.xcmPrecompileAvailable().catch(() => false),
        ]);
        setDispatchCount(count.toString());
        setPending(pend.toString());
        setInTransit(ethers.formatEther(transit));
        setXcmAvailable(avail as boolean);

        // Load recent dispatches (last 20)
        const total = Number(count);
        const start = Math.max(0, total - 20);
        const arr: DispatchData[] = [];
        for (let i = total - 1; i >= start; i--) {
          try {
            const d = await c.xcmRouter.getDispatch(i);
            arr.push({
              id: i, routeId: Number(d[0]), paraId: Number(d[1]),
              amount: d[2], status: Number(d[3]),
              xcmMessageHash: d[4],
              dispatchedAt: d[5], confirmedAt: d[6], timeoutAt: d[7],
            });
          } catch { /* skip */ }
        }
        setDispatches(arr);
      } catch (e) { console.error("XCM fetch:", e); }
    })();
  }, []);

  const statusVariant = (s: number): "success" | "warning" | "danger" | "info" | "neutral" => {
    if (s === 0) return "warning";  // Pending
    if (s === 1) return "info";     // Dispatched
    if (s === 2) return "success";  // Confirmed
    if (s === 3) return "danger";   // Failed
    if (s === 4) return "danger";   // TimedOut
    return "neutral";
  };

  // Parachain distribution for pie chart
  const paraDistribution = dispatches.reduce<Record<number, number>>((acc, d) => {
    acc[d.paraId] = (acc[d.paraId] || 0) + 1;
    return acc;
  }, {});
  const pieData = Object.entries(paraDistribution).map(([paraId, count]) => ({
    name: PARACHAINS[Number(paraId)]?.name ?? `Para #${paraId}`,
    value: count,
    color: PARACHAINS[Number(paraId)]?.color ?? "#6366f1",
  }));

  const columns = [
    { header: "ID", accessor: (d: DispatchData) => <span className="font-mono text-xs">#{d.id}</span> },
    {
      header: "Parachain",
      accessor: (d: DispatchData) => {
        const para = PARACHAINS[d.paraId];
        return (
          <span className="flex items-center gap-1.5">
            <span>{para?.icon ?? "🔗"}</span>
            <span>{para?.name ?? `#${d.paraId}`}</span>
          </span>
        );
      },
    },
    { header: "Amount", accessor: (d: DispatchData) => `${ethers.formatEther(d.amount)} WND` },
    {
      header: "Status",
      accessor: (d: DispatchData) => <Badge variant={statusVariant(d.status)}>{XCM_STATUSES[d.status]}</Badge>,
    },
    {
      header: "XCM Hash",
      accessor: (d: DispatchData) => (
        <span className="font-mono text-[11px] text-zinc-500">
          {d.xcmMessageHash === ethers.ZeroHash ? "—" : `${d.xcmMessageHash.slice(0, 10)}...`}
        </span>
      ),
    },
    { header: "Route", accessor: (d: DispatchData) => <span className="font-mono text-xs">#{d.routeId}</span> },
    {
      header: "Dispatched",
      accessor: (d: DispatchData) => {
        if (Number(d.dispatchedAt) === 0) return "—";
        return <span className="text-xs text-zinc-500">{new Date(Number(d.dispatchedAt) * 1000).toLocaleString()}</span>;
      },
    },
  ];

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">XCM Explorer</h1>
          <p className="mt-1 text-sm text-zinc-500">Monitor cross-chain message dispatches, packet traces, and parachain routes</p>
        </div>

        {/* Stats */}
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <StatCard label="Total Dispatches" value={dispatchCount} icon={<Globe size={16} />} tooltip="All XCM dispatches sent" />
          <StatCard label="Pending" value={pending} icon={<Clock size={16} />} tooltip="Dispatches awaiting confirmation" />
          <StatCard label="In Transit" value={`${parseFloat(inTransit).toFixed(4)} WND`} icon={<ArrowRight size={16} />} tooltip="Total value currently being routed" />
          <StatCard
            label="XCM Precompile"
            value={xcmAvailable ? "Available" : "Unavailable"}
            icon={<Zap size={16} />}
            tooltip="Whether the XCM precompile is accessible on this chain"
          />
        </div>

        <div className="grid gap-6 lg:grid-cols-3">
          {/* Parachain Channels */}
          <GlassCard title="Parachain Channels" icon={<Radio size={18} className="text-purple-400" />}>
            <div className="space-y-3">
              {Object.entries(PARACHAINS).map(([id, para]) => (
                <div key={id} className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium text-zinc-300">
                      {para.icon} {para.name}
                    </span>
                    <div className="flex items-center gap-1.5">
                      <PulseDot color="emerald" />
                      <Badge variant="success">Connected</Badge>
                    </div>
                  </div>
                  <p className="mt-1 font-mono text-[11px] text-zinc-600">Para ID: {id}</p>
                  <div className="mt-2 flex items-center gap-3 text-xs text-zinc-500">
                    <span>{paraDistribution[Number(id)] ?? 0} dispatches</span>
                  </div>
                </div>
              ))}
            </div>

            {/* Pie chart */}
            {pieData.length > 0 && (
              <div className="mt-4 h-48">
                <ResponsiveContainer width="100%" height="100%">
                  <PieChart>
                    <Pie data={pieData} cx="50%" cy="50%" innerRadius={40} outerRadius={70} paddingAngle={5} dataKey="value">
                      {pieData.map((d, i) => (
                        <Cell key={i} fill={d.color} />
                      ))}
                    </Pie>
                    <RTooltip contentStyle={{ backgroundColor: "#18181b", border: "1px solid #3f3f46", borderRadius: "8px", fontSize: "12px" }} />
                  </PieChart>
                </ResponsiveContainer>
                <div className="flex justify-center gap-3">
                  {pieData.map((d) => (
                    <span key={d.name} className="flex items-center gap-1 text-xs text-zinc-500">
                      <span className="h-2 w-2 rounded-full" style={{ backgroundColor: d.color }} />
                      {d.name}
                    </span>
                  ))}
                </div>
              </div>
            )}
          </GlassCard>

          {/* Dispatch Log */}
          <GlassCard title="Recent Dispatches" icon={<Globe size={18} className="text-indigo-400" />} className="lg:col-span-2">
            {dispatches.length === 0 ? (
              <EmptyState icon="📡" title="No dispatches" description="No XCM dispatches have been sent yet." />
            ) : (
              <DataTable columns={columns} data={dispatches} />
            )}
          </GlassCard>
        </div>

        {/* Packet Trace */}
        {dispatches.length > 0 && (
          <GlassCard title="Packet Trace Visualization" icon={<ArrowRight size={18} className="text-emerald-400" />}>
            <div className="flex items-center gap-4 overflow-x-auto pb-2">
              {dispatches.slice(0, 5).map((d) => {
                const para = PARACHAINS[d.paraId];
                return (
                  <div key={d.id} className="flex flex-shrink-0 items-center gap-2">
                    <div className="rounded-lg border border-zinc-800 bg-zinc-800/50 px-3 py-2 text-center">
                      <p className="text-[10px] text-zinc-500">Hub</p>
                      <p className="font-mono text-xs text-zinc-300">#{d.id}</p>
                    </div>
                    <div className="flex items-center gap-1">
                      <div className={`h-px w-8 ${d.status === 2 ? "bg-emerald-500" : d.status >= 3 ? "bg-red-500" : "bg-amber-500"}`} />
                      <ArrowRight size={12} className={d.status === 2 ? "text-emerald-500" : d.status >= 3 ? "text-red-500" : "text-amber-500"} />
                    </div>
                    <div className="rounded-lg border border-zinc-800 bg-zinc-800/50 px-3 py-2 text-center">
                      <p className="text-[10px] text-zinc-500">{para?.name ?? `#${d.paraId}`}</p>
                      <Badge variant={statusVariant(d.status)}>{XCM_STATUSES[d.status]}</Badge>
                    </div>
                  </div>
                );
              })}
            </div>
          </GlassCard>
        )}
      </div>
    </PageTransition>
  );
}
