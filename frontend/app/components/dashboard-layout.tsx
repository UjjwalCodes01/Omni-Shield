"use client";

import { ReactNode, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { motion, AnimatePresence } from "framer-motion";
import {
  LayoutDashboard,
  TrendingUp,
  Shield,
  Lock,
  Globe,
  Cpu,
  Radar,
  Users,
  Scale,
  Settings,
  Menu,
  X,
  Wallet,
  ExternalLink,
  ChevronDown,
} from "lucide-react";
import { cn } from "../lib/cn";
import { useWalletContext } from "./wallet-provider";
import { PulseDot, Button } from "./ui";
import { POLKADOT_HUB_TESTNET } from "../lib/stealth";

// ============================================================================
// Navigation Items
// ============================================================================

const NAV_ITEMS = [
  { href: "/", label: "Overview", icon: LayoutDashboard, description: "Omni-Balance Dashboard" },
  { href: "/yield", label: "Yield Hub", icon: TrendingUp, description: "Cross-Chain Optimizer" },
  { href: "/stealth", label: "Stealth Vault", icon: Shield, description: "Privacy Management" },
  { href: "/escrow", label: "Escrow Center", icon: Lock, description: "Conditional Payments" },
  { href: "/xcm", label: "XCM Explorer", icon: Globe, description: "Cross-Chain Monitor" },
  { href: "/pvm", label: "PVM & Registry", icon: Cpu, description: "Crypto Benchmarks" },
  { href: "/scanner", label: "Stealth Scanner", icon: Radar, description: "Manual Scan" },
  { href: "/payroll", label: "B2B Payroll", icon: Users, description: "Privacy Batching" },
  { href: "/disputes", label: "Disputes", icon: Scale, description: "Resolution Portal" },
  { href: "/settings", label: "Settings", icon: Settings, description: "Wallet & Auth" },
] as const;

// ============================================================================
// Sidebar
// ============================================================================

function Sidebar({ collapsed, onToggle }: { collapsed: boolean; onToggle: () => void }) {
  const pathname = usePathname();

  return (
    <aside
      className={cn(
        "fixed left-0 top-0 z-40 flex h-screen flex-col border-r border-zinc-800 bg-zinc-950/95 backdrop-blur-xl transition-all duration-300",
        collapsed ? "w-16" : "w-64"
      )}
    >
      {/* Logo */}
      <div className="flex h-16 items-center justify-between border-b border-zinc-800 px-4">
        {!collapsed && (
          <Link href="/" className="flex items-center gap-2">
            <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-indigo-600 text-sm font-bold text-white">
              OS
            </div>
            <div>
              <h1 className="text-sm font-bold tracking-tight text-zinc-100">
                <span className="text-indigo-400">Omni</span>Shield
              </h1>
              <p className="text-[10px] text-zinc-600">Polkadot Privacy Suite</p>
            </div>
          </Link>
        )}
        <button
          onClick={onToggle}
          className="flex h-8 w-8 items-center justify-center rounded-lg text-zinc-500 transition hover:bg-zinc-800 hover:text-zinc-300"
        >
          {collapsed ? <Menu size={16} /> : <X size={16} />}
        </button>
      </div>

      {/* Nav */}
      <nav className="flex-1 overflow-y-auto px-2 py-4">
        <div className="space-y-1">
          {NAV_ITEMS.map((item) => {
            const isActive = pathname === item.href;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "group flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-all",
                  isActive
                    ? "bg-indigo-600/10 text-indigo-400"
                    : "text-zinc-400 hover:bg-zinc-800/50 hover:text-zinc-200"
                )}
              >
                <item.icon
                  size={18}
                  className={cn(
                    "shrink-0 transition",
                    isActive ? "text-indigo-400" : "text-zinc-500 group-hover:text-zinc-400"
                  )}
                />
                {!collapsed && (
                  <div className="min-w-0">
                    <span className="block truncate">{item.label}</span>
                    <span className="block truncate text-[10px] font-normal text-zinc-600">
                      {item.description}
                    </span>
                  </div>
                )}
                {isActive && !collapsed && (
                  <div className="ml-auto h-1.5 w-1.5 rounded-full bg-indigo-400" />
                )}
              </Link>
            );
          })}
        </div>
      </nav>

      {/* Footer */}
      {!collapsed && (
        <div className="border-t border-zinc-800 p-4">
          <div className="flex items-center gap-2 text-[10px] text-zinc-600">
            <PulseDot color="emerald" />
            <span>Polkadot Hub TestNet</span>
          </div>
          <a
            href="https://blockscout-testnet.polkadot.io/"
            target="_blank"
            rel="noopener noreferrer"
            className="mt-2 flex items-center gap-1 text-[10px] text-zinc-600 transition hover:text-zinc-400"
          >
            <ExternalLink size={10} />
            Blockscout Explorer
          </a>
        </div>
      )}
    </aside>
  );
}

// ============================================================================
// Mobile Navigation
// ============================================================================

function MobileNav({ open, onClose }: { open: boolean; onClose: () => void }) {
  const pathname = usePathname();

  return (
    <AnimatePresence>
      {open && (
        <>
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 z-40 bg-black/60 backdrop-blur-sm"
            onClick={onClose}
          />
          <motion.div
            initial={{ x: -280 }}
            animate={{ x: 0 }}
            exit={{ x: -280 }}
            transition={{ type: "spring", damping: 25, stiffness: 200 }}
            className="fixed left-0 top-0 z-50 h-screen w-72 border-r border-zinc-800 bg-zinc-950 p-4"
          >
            <div className="mb-4 flex items-center justify-between">
              <h1 className="text-sm font-bold text-zinc-100">
                <span className="text-indigo-400">Omni</span>Shield
              </h1>
              <button onClick={onClose} className="text-zinc-500 hover:text-zinc-300">
                <X size={18} />
              </button>
            </div>
            <nav className="space-y-1">
              {NAV_ITEMS.map((item) => {
                const isActive = pathname === item.href;
                return (
                  <Link
                    key={item.href}
                    href={item.href}
                    onClick={onClose}
                    className={cn(
                      "flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition",
                      isActive
                        ? "bg-indigo-600/10 text-indigo-400"
                        : "text-zinc-400 hover:bg-zinc-800/50 hover:text-zinc-200"
                    )}
                  >
                    <item.icon size={18} />
                    {item.label}
                  </Link>
                );
              })}
            </nav>
          </motion.div>
        </>
      )}
    </AnimatePresence>
  );
}

// ============================================================================
// Top Bar
// ============================================================================

function TopBar({ onMenuClick }: { onMenuClick: () => void }) {
  const { wallet, connect, disconnect, switchToPolkadotHub, isCorrectChain } = useWalletContext();
  const [dropdown, setDropdown] = useState(false);

  return (
    <header className="sticky top-0 z-30 flex h-16 items-center justify-between border-b border-zinc-800 bg-zinc-950/80 px-6 backdrop-blur-xl">
      <button
        onClick={onMenuClick}
        className="mr-4 flex h-8 w-8 items-center justify-center rounded-lg text-zinc-500 transition hover:bg-zinc-800 hover:text-zinc-300 lg:hidden"
      >
        <Menu size={18} />
      </button>

      <div className="flex items-center gap-2">
        <PulseDot color={wallet.connected ? (isCorrectChain ? "emerald" : "amber") : "red"} />
        <span className="text-xs text-zinc-500">
          {wallet.connected
            ? isCorrectChain
              ? "Polkadot Hub TestNet"
              : `Wrong Chain (${wallet.chainId})`
            : "Disconnected"}
        </span>
      </div>

      <div className="flex items-center gap-3">
        {wallet.connected ? (
          <div className="relative">
            <button
              onClick={() => setDropdown(!dropdown)}
              className="flex items-center gap-2 rounded-lg border border-zinc-700 bg-zinc-800/50 px-3 py-1.5 text-sm text-zinc-300 transition hover:border-zinc-600"
            >
              <Wallet size={14} />
              <span className="font-mono text-xs">
                {wallet.address.slice(0, 6)}...{wallet.address.slice(-4)}
              </span>
              <span className="text-xs text-zinc-500">
                {parseFloat(wallet.balance).toFixed(2)} WND
              </span>
              <ChevronDown size={12} className="text-zinc-500" />
            </button>

            <AnimatePresence>
              {dropdown && (
                <motion.div
                  initial={{ opacity: 0, y: -4 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -4 }}
                  className="absolute right-0 top-full mt-2 w-48 rounded-lg border border-zinc-700 bg-zinc-900 p-2 shadow-2xl"
                >
                  {!isCorrectChain && (
                    <button
                      onClick={() => { switchToPolkadotHub(); setDropdown(false); }}
                      className="flex w-full items-center gap-2 rounded-md px-3 py-2 text-xs text-amber-400 transition hover:bg-zinc-800"
                    >
                      Switch to Polkadot Hub
                    </button>
                  )}
                  <a
                    href={`https://blockscout-testnet.polkadot.io/address/${wallet.address}`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="flex w-full items-center gap-2 rounded-md px-3 py-2 text-xs text-zinc-400 transition hover:bg-zinc-800 hover:text-zinc-200"
                  >
                    <ExternalLink size={12} />
                    View on Explorer
                  </a>
                  <button
                    onClick={() => { disconnect(); setDropdown(false); }}
                    className="flex w-full items-center gap-2 rounded-md px-3 py-2 text-xs text-red-400 transition hover:bg-zinc-800"
                  >
                    Disconnect
                  </button>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        ) : (
          <Button onClick={connect} size="sm">
            <Wallet size={14} />
            Connect Wallet
          </Button>
        )}
      </div>
    </header>
  );
}

// ============================================================================
// Dashboard Layout
// ============================================================================

export function DashboardLayout({ children }: { children: ReactNode }) {
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);

  return (
    <div className="min-h-screen bg-gradient-to-b from-zinc-950 via-zinc-900 to-zinc-950 font-sans text-zinc-100">
      {/* Desktop Sidebar */}
      <div className="hidden lg:block">
        <Sidebar
          collapsed={sidebarCollapsed}
          onToggle={() => setSidebarCollapsed(!sidebarCollapsed)}
        />
      </div>

      {/* Mobile Nav */}
      <MobileNav open={mobileOpen} onClose={() => setMobileOpen(false)} />

      {/* Main Content */}
      <div
        className={cn(
          "transition-all duration-300",
          sidebarCollapsed ? "lg:ml-16" : "lg:ml-64"
        )}
      >
        <TopBar onMenuClick={() => setMobileOpen(true)} />
        <main className="p-6">{children}</main>
      </div>
    </div>
  );
}
