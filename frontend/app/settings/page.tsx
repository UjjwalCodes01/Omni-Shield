"use client";

import { useState, useCallback } from "react";
import { ethers } from "ethers";
import {
  Settings as SettingsIcon, Wallet, Globe, Shield, ExternalLink,
  RefreshCw, Copy, CheckCircle2, Moon, Sun, AlertTriangle,
} from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  GlassCard, Badge, Button, Input, PageTransition, MonoBox, PulseDot,
} from "../components/ui";
import { CONTRACT_ADDRESSES, PARACHAINS } from "../lib/contracts";
import { POLKADOT_HUB_TESTNET } from "../lib/stealth";

// ============================================================================
// Page
// ============================================================================

export default function SettingsPage() {
  const { wallet, connect, disconnect, switchToPolkadotHub, isCorrectChain } = useWalletContext();
  const [copied, setCopied] = useState("");

  // H160 ↔ AccountId32 mapping
  const [h160Input, setH160Input] = useState("");
  const [accountId32Result, setAccountId32Result] = useState("");

  const copyToClipboard = useCallback((text: string, label: string) => {
    navigator.clipboard.writeText(text);
    setCopied(label);
    setTimeout(() => setCopied(""), 2000);
  }, []);

  const handleH160ToAccountId32 = useCallback(() => {
    if (!h160Input) return;
    try {
      // Polkadot H160 ↔ AccountId32 mapping
      // AccountId32 = blake2b(b"evm:" + h160_address + 12_zero_bytes)
      // Simplified: pad the H160 address to 32 bytes for display
      const clean = h160Input.toLowerCase().replace("0x", "");
      const padded = clean.padEnd(64, "0");
      setAccountId32Result("0x" + padded);
    } catch (e) {
      setAccountId32Result("Invalid address");
    }
  }, [h160Input]);

  const CopyBtn = ({ text, label }: { text: string; label: string }) => (
    <button onClick={() => copyToClipboard(text, label)} className="text-zinc-500 hover:text-zinc-300 transition">
      {copied === label ? <CheckCircle2 size={14} className="text-emerald-400" /> : <Copy size={14} />}
    </button>
  );

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">Settings</h1>
          <p className="mt-1 text-sm text-zinc-500">Wallet management, network configuration, and Substrate interop</p>
        </div>

        <div className="grid gap-6 lg:grid-cols-2">
          {/* Wallet */}
          <GlassCard title="Wallet" icon={<Wallet size={18} className="text-indigo-400" />}>
            <div className="space-y-4">
              {wallet.connected ? (
                <>
                  <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-4">
                    <div className="flex items-center justify-between">
                      <span className="text-xs text-zinc-500">Status</span>
                      <div className="flex items-center gap-1.5">
                        <PulseDot color={isCorrectChain ? "emerald" : "amber"} />
                        <Badge variant={isCorrectChain ? "success" : "warning"}>
                          {isCorrectChain ? "Connected" : "Wrong Chain"}
                        </Badge>
                      </div>
                    </div>
                  </div>
                  <div>
                    <div className="flex items-center justify-between">
                      <span className="text-xs text-zinc-500">Address</span>
                      <CopyBtn text={wallet.address} label="addr" />
                    </div>
                    <p className="mt-1 truncate font-mono text-sm text-zinc-300">{wallet.address}</p>
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <span className="text-xs text-zinc-500">Balance</span>
                      <p className="mt-1 text-lg font-bold text-zinc-100">{parseFloat(wallet.balance).toFixed(4)} WND</p>
                    </div>
                    <div>
                      <span className="text-xs text-zinc-500">Chain ID</span>
                      <p className="mt-1 font-mono text-sm text-zinc-300">{wallet.chainId}</p>
                    </div>
                  </div>
                  <div className="flex gap-3">
                    {!isCorrectChain && (
                      <Button variant="danger" onClick={switchToPolkadotHub}>
                        <RefreshCw size={14} /> Switch to Polkadot Hub
                      </Button>
                    )}
                    <Button variant="secondary" onClick={disconnect}>Disconnect</Button>
                  </div>
                </>
              ) : (
                <div className="text-center py-8">
                  <Wallet size={32} className="mx-auto mb-3 text-zinc-600" />
                  <p className="text-sm text-zinc-400">No wallet connected</p>
                  <Button onClick={connect} className="mt-4">Connect MetaMask</Button>
                </div>
              )}
            </div>
          </GlassCard>

          {/* Network */}
          <GlassCard title="Network Configuration" icon={<Globe size={18} className="text-emerald-400" />}>
            <div className="space-y-4">
              <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 p-4">
                <div className="flex items-center justify-between">
                  <span className="text-sm font-medium text-zinc-200">Polkadot Hub TestNet</span>
                  <Badge variant="success">Target Network</Badge>
                </div>
                <div className="mt-3 space-y-2">
                  <div className="flex items-center justify-between text-xs">
                    <span className="text-zinc-500">Chain ID</span>
                    <span className="font-mono text-zinc-300">{POLKADOT_HUB_TESTNET.chainId}</span>
                  </div>
                  <div className="flex items-center justify-between text-xs">
                    <span className="text-zinc-500">RPC URL</span>
                    <span className="font-mono text-zinc-300 truncate max-w-[200px]">{POLKADOT_HUB_TESTNET.rpcUrl}</span>
                  </div>
                  <div className="flex items-center justify-between text-xs">
                    <span className="text-zinc-500">Currency</span>
                    <span className="text-zinc-300">WND (Westend)</span>
                  </div>
                </div>
              </div>

              <div>
                <p className="mb-2 text-xs font-medium text-zinc-400">Parachain Endpoints</p>
                <div className="space-y-2">
                  {Object.entries(PARACHAINS).map(([id, para]) => (
                    <div key={id} className="flex items-center justify-between rounded-lg border border-zinc-800 bg-zinc-800/30 px-3 py-2">
                      <span className="text-xs text-zinc-300">{para.icon} {para.name}</span>
                      <span className="font-mono text-[11px] text-zinc-500">Para ID: {id}</span>
                    </div>
                  ))}
                </div>
              </div>

              <a
                href="https://blockscout-testnet.polkadot.io/"
                target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-2 text-xs text-indigo-400 hover:underline"
              >
                <ExternalLink size={12} /> Blockscout Explorer
              </a>
            </div>
          </GlassCard>

          {/* H160 ↔ AccountId32 */}
          <GlassCard title="H160 ↔ AccountId32 Mapping" icon={<Shield size={18} className="text-purple-400" />}>
            <div className="space-y-3">
              <p className="text-xs text-zinc-500">
                Map EVM H160 addresses to Substrate AccountId32. Useful for cross-chain identity linking.
              </p>
              <Input label="H160 Address (0x...)" value={h160Input} onChange={setH160Input} placeholder="0x..." />
              <Button variant="secondary" onClick={handleH160ToAccountId32} disabled={!h160Input}>
                Convert to AccountId32
              </Button>
              {accountId32Result && <MonoBox label="AccountId32 (padded)" value={accountId32Result} />}
              <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3">
                <div className="flex items-start gap-2">
                  <AlertTriangle size={14} className="mt-0.5 text-amber-400" />
                  <p className="text-[11px] text-zinc-500">
                    This is a simplified padding. The real Substrate AccountId32 derivation uses blake2b hashing with the &quot;evm:&quot; prefix. See CryptoRegistry for on-chain derivation.
                  </p>
                </div>
              </div>
            </div>
          </GlassCard>

          {/* Deployed Contracts */}
          <GlassCard title="Contract Addresses" icon={<SettingsIcon size={18} className="text-amber-400" />}>
            <div className="space-y-2">
              {Object.entries(CONTRACT_ADDRESSES).map(([name, addr]) => (
                <div key={name} className="flex items-center justify-between rounded-lg border border-zinc-800 bg-zinc-800/30 px-3 py-2">
                  <span className="text-xs font-medium capitalize text-zinc-400">{name.replace(/([A-Z])/g, " $1").trim()}</span>
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-[11px] text-zinc-500">{addr.slice(0, 8)}...{addr.slice(-6)}</span>
                    <CopyBtn text={addr} label={name} />
                    <a
                      href={`https://blockscout-testnet.polkadot.io/address/${addr}`}
                      target="_blank" rel="noopener noreferrer"
                      className="text-zinc-500 hover:text-zinc-300 transition"
                    >
                      <ExternalLink size={12} />
                    </a>
                  </div>
                </div>
              ))}
            </div>
          </GlassCard>
        </div>

        {/* About */}
        <GlassCard title="About OmniShield" icon={<Shield size={18} className="text-indigo-400" />}>
          <div className="grid gap-4 sm:grid-cols-3">
            <div>
              <p className="text-xs text-zinc-500">Version</p>
              <p className="mt-1 text-sm font-medium text-zinc-200">v1.0 (Day 15-17)</p>
            </div>
            <div>
              <p className="text-xs text-zinc-500">Deployment</p>
              <p className="mt-1 text-sm font-medium text-zinc-200">V6 — All Contracts Verified</p>
            </div>
            <div>
              <p className="text-xs text-zinc-500">Test Suite</p>
              <p className="mt-1 text-sm font-medium text-zinc-200">407 Tests Passing</p>
            </div>
          </div>
          <div className="mt-4 rounded-lg border border-zinc-800 bg-zinc-800/30 p-3">
            <p className="text-xs text-zinc-400 leading-relaxed">
              OmniShield is a privacy-preserving cross-chain DeFi protocol built for the Polkadot Solidity Hackathon.
              It combines EIP-5564 stealth payments, commitment-based vaults, conditional escrow, cross-chain yield routing via XCM,
              and PVM precompile integration for native Substrate cryptography.
            </p>
          </div>
        </GlassCard>
      </div>
    </PageTransition>
  );
}
