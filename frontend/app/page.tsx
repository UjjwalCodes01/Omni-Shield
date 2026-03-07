"use client";

import { useEffect, useState } from "react";
import { ethers } from "ethers";
import Link from "next/link";
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid,
  ResponsiveContainer, Tooltip as RTooltip,
} from "recharts";
import {
  Shield, TrendingUp, Lock, Globe, Send, ArrowDownToLine,
  Activity, Wallet, Layers, Zap,
} from "lucide-react";
import { useWalletContext } from "./components/wallet-provider";
import { StatCard, GlassCard, Badge, PulseDot, Button, PageTransition } from "./components/ui";
import {
  CONTRACT_ADDRESSES, getContracts, PARACHAINS,
} from "./lib/contracts";
import { POLKADOT_HUB_TESTNET, STEALTH_PAYMENT_ABI, STEALTH_VAULT_ABI } from "./lib/stealth";

// ============================================================================
// Chart data for demo (represents TVL over last 7 days)
// ============================================================================
const chartData = [
  { day: "Mon", tvl: 12400, stealth: 3200, escrow: 4100, yield: 5100 },
  { day: "Tue", tvl: 14200, stealth: 3800, escrow: 4500, yield: 5900 },
  { day: "Wed", tvl: 13800, stealth: 3600, escrow: 4200, yield: 6000 },
  { day: "Thu", tvl: 16100, stealth: 4200, escrow: 5000, yield: 6900 },
  { day: "Fri", tvl: 18500, stealth: 5000, escrow: 5500, yield: 8000 },
  { day: "Sat", tvl: 20200, stealth: 5400, escrow: 6200, yield: 8600 },
  { day: "Sun", tvl: 22800, stealth: 6100, escrow: 6800, yield: 9900 },
];

const quickActions = [
  { label: "Send Privately", icon: Send, href: "/stealth", color: "text-indigo-400" },
  { label: "Deposit for Yield", icon: ArrowDownToLine, href: "/yield", color: "text-emerald-400" },
  { label: "Check Escrows", icon: Lock, href: "/escrow", color: "text-amber-400" },
  { label: "Scan Payments", icon: Activity, href: "/scanner", color: "text-purple-400" },
];

export default function OverviewPage() {
  const { wallet } = useWalletContext();
  const [stats, setStats] = useState({
    announcements: "—", vaultDeposits: "—", escrowCount: "—",
    yieldSources: "—", xcmDispatches: "—", pendingXcm: "—", amountInTransit: "—",
  });

  useEffect(() => {
    (async () => {
      try {
        const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
        const c = getContracts(provider);
        const sp = new ethers.Contract(CONTRACT_ADDRESSES.stealthPayment, STEALTH_PAYMENT_ABI, provider);
        const sv = new ethers.Contract(CONTRACT_ADDRESSES.stealthVault, STEALTH_VAULT_ABI, provider);
        const [ann, dep, esc, src, disp, pend, transit] = await Promise.all([
          sp.getAnnouncementCount().catch(() => BigInt(0)),
          sv.getDepositCount().catch(() => BigInt(0)),
          c.escrow.getEscrowCount().catch(() => BigInt(0)),
          c.yieldRouter.getYieldSourceCount().catch(() => BigInt(0)),
          c.xcmRouter.getDispatchCount().catch(() => BigInt(0)),
          c.xcmRouter.pendingDispatches().catch(() => BigInt(0)),
          c.xcmRouter.amountInTransit().catch(() => BigInt(0)),
        ]);
        setStats({
          announcements: ann.toString(), vaultDeposits: dep.toString(),
          escrowCount: esc.toString(), yieldSources: src.toString(),
          xcmDispatches: disp.toString(), pendingXcm: pend.toString(),
          amountInTransit: ethers.formatEther(transit),
        });
      } catch (e) { console.error("Stats fetch failed:", e); }
    })();
  }, []);

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">Executive Overview</h1>
          <p className="mt-1 text-sm text-zinc-500">Omni-Balance dashboard — Total assets across Escrow, Stealth, and Yield</p>
        </div>

        {/* Quick Actions */}
        <GlassCard>
          <div className="flex flex-wrap gap-3">
            {quickActions.map((a) => (
              <Link key={a.href} href={a.href}>
                <Button variant="secondary" size="sm">
                  <a.icon size={14} className={a.color} />
                  {a.label}
                </Button>
              </Link>
            ))}
          </div>
        </GlassCard>

        {/* Stats */}
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <StatCard label="Stealth Announcements" value={stats.announcements} icon={<Shield size={16} />} tooltip="Total EIP-5564 stealth payment announcements" />
          <StatCard label="Vault Deposits" value={stats.vaultDeposits} icon={<Lock size={16} />} tooltip="Commitment-based privacy vault deposits" />
          <StatCard label="Active Escrows" value={stats.escrowCount} icon={<Layers size={16} />} tooltip="Total escrow contracts created" />
          <StatCard label="Yield Sources" value={stats.yieldSources} icon={<TrendingUp size={16} />} tooltip="Parachain yield protocols available" />
        </div>

        {/* Chart + Infrastructure */}
        <div className="grid gap-6 lg:grid-cols-3">
          <GlassCard title="Protocol TVL" icon={<TrendingUp size={18} className="text-indigo-400" />} className="lg:col-span-2">
            <div className="h-64">
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={chartData}>
                  <defs>
                    <linearGradient id="tvlG" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor="#6366f1" stopOpacity={0.3} /><stop offset="95%" stopColor="#6366f1" stopOpacity={0} /></linearGradient>
                    <linearGradient id="stG" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor="#8b5cf6" stopOpacity={0.2} /><stop offset="95%" stopColor="#8b5cf6" stopOpacity={0} /></linearGradient>
                    <linearGradient id="ylG" x1="0" y1="0" x2="0" y2="1"><stop offset="5%" stopColor="#10b981" stopOpacity={0.2} /><stop offset="95%" stopColor="#10b981" stopOpacity={0} /></linearGradient>
                  </defs>
                  <CartesianGrid strokeDasharray="3 3" stroke="#27272a" />
                  <XAxis dataKey="day" tick={{ fill: "#71717a", fontSize: 12 }} />
                  <YAxis tick={{ fill: "#71717a", fontSize: 12 }} />
                  <RTooltip contentStyle={{ backgroundColor: "#18181b", border: "1px solid #3f3f46", borderRadius: "8px", fontSize: "12px" }} />
                  <Area type="monotone" dataKey="yield" stroke="#10b981" fill="url(#ylG)" strokeWidth={2} />
                  <Area type="monotone" dataKey="stealth" stroke="#8b5cf6" fill="url(#stG)" strokeWidth={2} />
                  <Area type="monotone" dataKey="tvl" stroke="#6366f1" fill="url(#tvlG)" strokeWidth={2} />
                </AreaChart>
              </ResponsiveContainer>
            </div>
            <div className="mt-3 flex gap-4 text-xs text-zinc-500">
              <span className="flex items-center gap-1"><span className="h-2 w-2 rounded-full bg-indigo-500" /> Total TVL</span>
              <span className="flex items-center gap-1"><span className="h-2 w-2 rounded-full bg-purple-500" /> Stealth</span>
              <span className="flex items-center gap-1"><span className="h-2 w-2 rounded-full bg-emerald-500" /> Yield</span>
            </div>
          </GlassCard>

          <GlassCard title="Live Infrastructure" icon={<Activity size={18} className="text-emerald-400" />}>
            <div className="space-y-4">
              <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
                <div className="flex items-center justify-between">
                  <span className="text-xs font-medium text-zinc-400">Backend Relayer</span>
                  <div className="flex items-center gap-1.5"><PulseDot color="emerald" /><span className="text-xs text-emerald-400">Online</span></div>
                </div>
                <p className="mt-1 text-[10px] text-zinc-600">Monitoring stealth events & XCM dispatches</p>
              </div>
              {Object.entries(PARACHAINS).map(([id, para]) => (
                <div key={id} className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
                  <div className="flex items-center justify-between">
                    <span className="text-xs font-medium text-zinc-400">{para.icon} {para.name} (#{id})</span>
                    <Badge variant="success">Active</Badge>
                  </div>
                </div>
              ))}
              <div className="space-y-2 border-t border-zinc-800 pt-3">
                <div className="flex items-center justify-between text-xs"><span className="text-zinc-500">XCM Dispatches</span><span className="font-mono text-zinc-300">{stats.xcmDispatches}</span></div>
                <div className="flex items-center justify-between text-xs"><span className="text-zinc-500">Pending XCM</span><span className="font-mono text-zinc-300">{stats.pendingXcm}</span></div>
                <div className="flex items-center justify-between text-xs"><span className="text-zinc-500">In Transit</span><span className="font-mono text-zinc-300">{stats.amountInTransit} WND</span></div>
              </div>
            </div>
          </GlassCard>
        </div>

        {/* Deployed Contracts */}
        <GlassCard title="Deployed Contracts" icon={<Zap size={18} className="text-amber-400" />}>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {Object.entries(CONTRACT_ADDRESSES).map(([name, addr]) => (
              <a key={name} href={`https://blockscout-testnet.polkadot.io/address/${addr}`} target="_blank" rel="noopener noreferrer" className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-3 transition hover:border-zinc-700">
                <p className="text-xs font-medium capitalize text-zinc-400">{name.replace(/([A-Z])/g, " $1").trim()}</p>
                <p className="mt-1 truncate font-mono text-[11px] text-zinc-500">{addr}</p>
              </a>
            ))}
          </div>
        </GlassCard>

        {wallet.connected && (
          <GlassCard title="Your Wallet" icon={<Wallet size={18} className="text-indigo-400" />}>
            <div className="grid gap-4 sm:grid-cols-3">
              <div><p className="text-xs text-zinc-500">Address</p><p className="mt-1 truncate font-mono text-sm text-zinc-300">{wallet.address}</p></div>
              <div><p className="text-xs text-zinc-500">Balance</p><p className="mt-1 text-sm font-semibold text-zinc-100">{parseFloat(wallet.balance).toFixed(4)} WND</p></div>
              <div><p className="text-xs text-zinc-500">Chain ID</p><p className="mt-1 text-sm text-zinc-300">{wallet.chainId}</p></div>
            </div>
          </GlassCard>
        )}
      </div>
    </PageTransition>
  );
}
