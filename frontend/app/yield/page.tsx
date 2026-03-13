"use client";

import { useEffect, useState, useCallback } from "react";
import { ethers } from "ethers";
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid,
  ResponsiveContainer, Tooltip as RTooltip, Cell,
} from "recharts";
import {
  TrendingUp, ArrowDownToLine, ArrowUpFromLine,
  RefreshCw, Zap, DollarSign, Layers,
} from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  StatCard, GlassCard, Badge, Button, Input, PageTransition,
  StatusStepper, DataTable, EmptyState, TxResult,
} from "../components/ui";
import {
  getContracts, CONTRACT_ADDRESSES, PARACHAINS,
  YIELD_ROUTER_ABI, ROUTE_STATUSES, type RouteStatusName,
} from "../lib/contracts";
import { POLKADOT_HUB_TESTNET } from "../lib/stealth";
import { useTx } from "../lib/hooks";

// ============================================================================
// Types
// ============================================================================

interface YieldSource {
  id: number;
  paraId: number;
  protocol: string;
  isActive: boolean;
  currentApyBps: bigint;
  totalDeposited: bigint;
  maxCapacity: bigint;
  lastUpdated: bigint;
}

interface UserRoute {
  id: number;
  user: string;
  sourceId: number;
  amount: bigint;
  status: number;
  depositTimestamp: bigint;
  estimatedYield: bigint;
}

// ============================================================================
// Page
// ============================================================================

export default function YieldHubPage() {
  const { wallet } = useWalletContext();
  const [sources, setSources] = useState<YieldSource[]>([]);
  const [routes, setRoutes] = useState<UserRoute[]>([]);
  const [tvl, setTvl] = useState("0");
  const [yieldReserve, setYieldReserve] = useState("0");
  const [minDeposit, setMinDeposit] = useState<bigint>(BigInt(0));
  const [depositAmount, setDepositAmount] = useState("");
  const [selectedSource, setSelectedSource] = useState<number | null>(null);
  const depositTx = useTx();
  const withdrawTx = useTx();

  // Fetch data
  useEffect(() => {
    (async () => {
      try {
        const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
        const c = getContracts(provider);
        const [count, locked, reserve, min] = await Promise.all([
          c.yieldRouter.getYieldSourceCount().catch(() => BigInt(0)),
          c.yieldRouter.totalValueLocked().catch(() => BigInt(0)),
          c.yieldRouter.yieldReserve().catch(() => BigInt(0)),
          c.yieldRouter.minDeposit().catch(() => BigInt(0)),
        ]);
        setTvl(ethers.formatEther(locked));
        setYieldReserve(ethers.formatEther(reserve));
        setMinDeposit(min);

        const srcArr: YieldSource[] = [];
        for (let i = 0; i < Number(count); i++) {
          try {
            const s = await c.yieldRouter.getYieldSource(i);
            srcArr.push({
              id: i,
              paraId: Number(s[0]),
              protocol: s[1],
              isActive: s[2],
              currentApyBps: s[3],
              totalDeposited: s[4],
              maxCapacity: s[5],
              lastUpdated: s[6],
            });
          } catch { /* skip */ }
        }
        setSources(srcArr);

        // Fetch user routes if connected
        if (wallet.address) {
          try {
            const ids = await c.yieldRouter.getUserRouteIds(wallet.address);
            const rtArr: UserRoute[] = [];
            for (const rid of ids) {
              const r = await c.yieldRouter.getUserRoute(rid);
              rtArr.push({
                id: Number(rid),
                user: r[0], sourceId: Number(r[1]), amount: r[2],
                status: Number(r[3]), depositTimestamp: r[4], estimatedYield: r[5],
              });
            }
            setRoutes(rtArr);
          } catch { /* no routes */ }
        }
      } catch (e) { console.error("Yield fetch:", e); }
    })();
  }, [wallet.address]);

  // Handlers
  const handleDeposit = useCallback(async () => {
    if (!wallet.signer || !depositAmount) return;

    let amountWei: bigint;
    try {
      amountWei = ethers.parseEther(depositAmount);
    } catch {
      depositTx.fail("Invalid deposit amount.");
      return;
    }

    if (amountWei <= 0) {
      depositTx.fail("Deposit amount must be greater than zero.");
      return;
    }

    if (amountWei < minDeposit) {
      depositTx.fail(`Minimum deposit is ${ethers.formatEther(minDeposit)} WND.`);
      return;
    }

    const activeSources = sources.filter((s) => s.isActive);
    if (activeSources.length === 0) {
      depositTx.fail("No active yield source is currently available.");
      return;
    }

    if (selectedSource !== null) {
      const source = sources.find((s) => s.id === selectedSource);
      if (!source) {
        depositTx.fail("Selected yield source does not exist.");
        return;
      }
      if (!source.isActive) {
        depositTx.fail("Selected yield source is not active.");
        return;
      }
      if (source.totalDeposited + amountWei > source.maxCapacity) {
        depositTx.fail("Selected yield source is at capacity.");
        return;
      }
    }

    const yr = new ethers.Contract(CONTRACT_ADDRESSES.yieldRouter, YIELD_ROUTER_ABI, wallet.signer);
    if (selectedSource !== null) {
      await depositTx.execute(() => yr.depositToSource(selectedSource, { value: amountWei }));
    } else {
      await depositTx.execute(() => yr.depositAndRoute({ value: amountWei }));
    }
  }, [wallet.signer, depositAmount, selectedSource, depositTx, minDeposit, sources]);

  const handleWithdraw = useCallback(async (routeId: number) => {
    if (!wallet.signer) return;
    const yr = new ethers.Contract(CONTRACT_ADDRESSES.yieldRouter, YIELD_ROUTER_ABI, wallet.signer);
    await withdrawTx.execute(() => yr.initiateWithdrawal(routeId));
  }, [wallet.signer, withdrawTx]);

  // Chart data from sources
  const chartData = sources.map((s) => ({
    name: PARACHAINS[s.paraId]?.name ?? `Para #${s.paraId}`,
    apy: Number(s.currentApyBps) / 100,
    deposited: parseFloat(ethers.formatEther(s.totalDeposited)),
    color: PARACHAINS[s.paraId]?.color ?? "#6366f1",
  }));

  const routeColumns = [
    { header: "ID", accessor: (r: UserRoute) => <span className="font-mono text-xs">#{r.id}</span> },
    {
      header: "Source",
      accessor: (r: UserRoute) => {
        const src = sources.find((s) => s.id === r.sourceId);
        return src ? `${PARACHAINS[src.paraId]?.icon ?? ""} ${src.protocol}` : `Source #${r.sourceId}`;
      },
    },
    { header: "Amount", accessor: (r: UserRoute) => `${ethers.formatEther(r.amount)} WND` },
    {
      header: "Status",
      accessor: (r: UserRoute) => {
        const name = ROUTE_STATUSES[r.status] ?? "Unknown";
        const variant = r.status === 1 ? "success" : r.status === 3 ? "info" : r.status === 4 ? "danger" : "neutral";
        return <Badge variant={variant as "success"|"info"|"danger"|"neutral"}>{name}</Badge>;
      },
    },
    {
      header: "Est. Yield",
      accessor: (r: UserRoute) => <span className="text-emerald-400">{ethers.formatEther(r.estimatedYield)} WND</span>,
    },
    {
      header: "",
      accessor: (r: UserRoute) =>
        r.status === 1 ? (
          <Button size="sm" variant="secondary" onClick={() => handleWithdraw(r.id)}>
            <ArrowUpFromLine size={12} /> Withdraw
          </Button>
        ) : null,
    },
  ];

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">Omni-Yield Hub</h1>
          <p className="mt-1 text-sm text-zinc-500">Cross-chain yield routing via XCM — deposit once, earn across parachains</p>
        </div>

        {/* Stats */}
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <StatCard label="Total Value Locked" value={`${parseFloat(tvl).toFixed(4)} WND`} icon={<DollarSign size={16} />} tooltip="Aggregated deposits across all yield sources" />
          <StatCard label="Yield Reserve" value={`${parseFloat(yieldReserve).toFixed(4)} WND`} icon={<Layers size={16} />} tooltip="Accumulated yield ready for withdrawal" />
          <StatCard label="Yield Sources" value={sources.length.toString()} icon={<Zap size={16} />} tooltip="Active parachain yield protocols" />
          <StatCard label="Your Routes" value={routes.length.toString()} icon={<TrendingUp size={16} />} tooltip="Your active yield routes" />
        </div>

        {/* APY Chart */}
        {chartData.length > 0 && (
          <GlassCard title="APY by Source" icon={<TrendingUp size={18} className="text-emerald-400" />}>
            <div className="h-56">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={chartData}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#27272a" />
                  <XAxis dataKey="name" tick={{ fill: "#71717a", fontSize: 12 }} />
                  <YAxis tick={{ fill: "#71717a", fontSize: 12 }} unit="%" />
                  <RTooltip contentStyle={{ backgroundColor: "#18181b", border: "1px solid #3f3f46", borderRadius: "8px", fontSize: "12px" }} />
                  <Bar dataKey="apy" radius={[6, 6, 0, 0]}>
                    {chartData.map((d, i) => (
                      <Cell key={i} fill={d.color} />
                    ))}
                  </Bar>
                </BarChart>
              </ResponsiveContainer>
            </div>
          </GlassCard>
        )}

        {/* Deposit + Parachain Cards */}
        <div className="grid gap-6 lg:grid-cols-3">
          {/* Deposit Form */}
          <GlassCard title="Deposit" icon={<ArrowDownToLine size={18} className="text-indigo-400" />}>
            <StatusStepper steps={[
              { label: "Amount", done: !!depositAmount, active: !depositAmount },
              { label: "Source", done: selectedSource !== null, active: !!depositAmount && selectedSource === null },
              { label: "Confirm", done: depositTx.status.success, active: !!depositAmount && selectedSource !== null },
            ]} />
            <div className="mt-4 space-y-3">
              <Input label="Amount (WND)" value={depositAmount} onChange={setDepositAmount} placeholder="0.01" type="number" />
              <p className="text-xs text-zinc-500">Minimum deposit: {ethers.formatEther(minDeposit)} WND</p>
              <div>
                <span className="mb-1 block text-sm text-zinc-400">Yield Source</span>
                <div className="space-y-2">
                  <button
                    onClick={() => setSelectedSource(null)}
                    className={`w-full rounded-lg border p-2 text-left text-xs transition ${
                      selectedSource === null ? "border-indigo-500 bg-indigo-500/10 text-indigo-400" : "border-zinc-700 bg-zinc-800/50 text-zinc-400 hover:border-zinc-600"
                    }`}
                  >
                    <RefreshCw size={12} className="mr-1.5 inline" /> Auto-select best APY
                  </button>
                  {sources.filter((s) => s.isActive).map((s) => (
                    <button
                      key={s.id}
                      onClick={() => setSelectedSource(s.id)}
                      className={`w-full rounded-lg border p-2 text-left text-xs transition ${
                        selectedSource === s.id ? "border-indigo-500 bg-indigo-500/10 text-indigo-400" : "border-zinc-700 bg-zinc-800/50 text-zinc-400 hover:border-zinc-600"
                      }`}
                    >
                      {PARACHAINS[s.paraId]?.icon} {s.protocol} — {(Number(s.currentApyBps) / 100).toFixed(2)}% APY
                    </button>
                  ))}
                </div>
              </div>
              <Button onClick={handleDeposit} disabled={!wallet.connected || !depositAmount || depositTx.status.pending}>
                {depositTx.status.pending ? "Routing..." : "Deposit & Route"}
              </Button>
              <TxResult label="Deposit" {...depositTx.status} />
            </div>
          </GlassCard>

          {/* Parachain Cards */}
          <div className="space-y-4 lg:col-span-2">
            <h3 className="text-sm font-medium text-zinc-400">Parachain Yield Sources</h3>
            {sources.length === 0 ? (
              <EmptyState icon="🌐" title="No yield sources" description="No parachain yield sources have been registered yet." />
            ) : (
              <div className="grid gap-3 sm:grid-cols-2">
                {sources.map((s) => {
                  const para = PARACHAINS[s.paraId];
                  return (
                    <div key={s.id} className="rounded-xl border border-zinc-800 bg-zinc-900/60 p-4 transition hover:border-zinc-700">
                      <div className="flex items-center justify-between">
                        <span className="text-sm font-medium text-zinc-200">
                          {para?.icon} {s.protocol}
                        </span>
                        <Badge variant={s.isActive ? "success" : "danger"}>{s.isActive ? "Active" : "Paused"}</Badge>
                      </div>
                      <div className="mt-3 grid grid-cols-2 gap-3">
                        <div>
                          <p className="text-xs text-zinc-500">APY</p>
                          <p className="text-lg font-bold text-emerald-400">{(Number(s.currentApyBps) / 100).toFixed(2)}%</p>
                        </div>
                        <div>
                          <p className="text-xs text-zinc-500">Para ID</p>
                          <p className="font-mono text-sm text-zinc-300">#{s.paraId}</p>
                        </div>
                        <div>
                          <p className="text-xs text-zinc-500">Deposited</p>
                          <p className="font-mono text-sm text-zinc-300">{parseFloat(ethers.formatEther(s.totalDeposited)).toFixed(4)}</p>
                        </div>
                        <div>
                          <p className="text-xs text-zinc-500">Capacity</p>
                          <p className="font-mono text-sm text-zinc-300">{parseFloat(ethers.formatEther(s.maxCapacity)).toFixed(4)}</p>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        </div>

        {/* Your Routes */}
        <GlassCard title="Your Yield Routes" icon={<TrendingUp size={18} className="text-indigo-400" />}>
          {routes.length === 0 ? (
            <EmptyState icon="📊" title="No active routes" description="Deposit funds to start earning cross-chain yield." />
          ) : (
            <DataTable columns={routeColumns} data={routes} />
          )}
          <TxResult label="Withdrawal" {...withdrawTx.status} />
        </GlassCard>
      </div>
    </PageTransition>
  );
}
