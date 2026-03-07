"use client";

import { useState, useCallback, useEffect } from "react";
import { ethers } from "ethers";
import { useWallet, useContracts, useTx } from "./lib/hooks";
import {
  generateStealthKeyPair,
  computeStealthPayment,
  computeCommitment,
  generateBlindingFactor,
  computeNullifier,
  scanForPayments,
  CONTRACT_ADDRESSES,
  type StealthKeyPair,
  type StealthPaymentData,
  type ScannedPayment,
  POLKADOT_HUB_TESTNET,
} from "./lib/stealth";

// ============================================================================
// Constants  (set after deployment — update these)
// ============================================================================
const SP_ADDR = process.env.NEXT_PUBLIC_STEALTH_PAYMENT ?? CONTRACT_ADDRESSES.stealthPayment;
const SV_ADDR = process.env.NEXT_PUBLIC_STEALTH_VAULT ?? CONTRACT_ADDRESSES.stealthVault;

// ============================================================================
// Utility components
// ============================================================================

function StatusBadge({ connected, chainId }: { connected: boolean; chainId: number }) {
  const isCorrectChain = chainId === POLKADOT_HUB_TESTNET.chainId;
  return (
    <div className="flex items-center gap-2 text-sm">
      <span
        className={`inline-block h-2 w-2 rounded-full ${
          connected
            ? isCorrectChain
              ? "bg-emerald-400"
              : "bg-amber-400"
            : "bg-zinc-500"
        }`}
      />
      {connected
        ? isCorrectChain
          ? "Polkadot Hub TestNet"
          : `Wrong chain (${chainId})`
        : "Disconnected"}
    </div>
  );
}

function TxResult({
  label,
  hash,
  error,
  pending,
  success,
}: {
  label: string;
  hash: string;
  error: string;
  pending: boolean;
  success: boolean;
}) {
  if (!pending && !hash && !error) return null;
  return (
    <div
      className={`mt-3 rounded-lg border p-3 text-sm ${
        error
          ? "border-red-500/40 bg-red-500/10 text-red-300"
          : success
            ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-300"
            : "border-zinc-700 bg-zinc-800/50 text-zinc-400"
      }`}
    >
      <p className="font-medium">
        {pending ? `${label} — Pending...` : error ? `${label} — Failed` : `${label} — Success`}
      </p>
      {hash && (
        <p className="mt-1 truncate font-mono text-xs opacity-70">
          tx: {hash}
        </p>
      )}
      {error && <p className="mt-1 text-xs opacity-70">{error}</p>}
    </div>
  );
}

function Card({
  title,
  children,
  icon,
}: {
  title: string;
  children: React.ReactNode;
  icon: string;
}) {
  return (
    <section className="rounded-xl border border-zinc-800 bg-zinc-900/50 p-6 backdrop-blur">
      <h2 className="mb-4 flex items-center gap-2 text-lg font-semibold text-zinc-100">
        <span className="text-xl">{icon}</span>
        {title}
      </h2>
      {children}
    </section>
  );
}

function Input({
  label,
  value,
  onChange,
  placeholder,
  type = "text",
  disabled = false,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  type?: string;
  disabled?: boolean;
}) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm text-zinc-400">{label}</span>
      <input
        type={type}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        disabled={disabled}
        className="w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-zinc-100 placeholder-zinc-600 transition focus:border-indigo-500 focus:outline-none disabled:opacity-50"
      />
    </label>
  );
}

function Btn({
  children,
  onClick,
  disabled = false,
  variant = "primary",
}: {
  children: React.ReactNode;
  onClick: () => void;
  disabled?: boolean;
  variant?: "primary" | "secondary" | "danger";
}) {
  const styles = {
    primary:
      "bg-indigo-600 hover:bg-indigo-500 text-white disabled:bg-indigo-600/50",
    secondary:
      "bg-zinc-700 hover:bg-zinc-600 text-zinc-100 disabled:bg-zinc-700/50",
    danger:
      "bg-red-600/80 hover:bg-red-500 text-white disabled:bg-red-600/30",
  };
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`rounded-lg px-4 py-2 text-sm font-medium transition ${styles[variant]} disabled:cursor-not-allowed`}
    >
      {children}
    </button>
  );
}

function MonoBox({ label, value }: { label: string; value: string }) {
  return (
    <div className="mt-2">
      <span className="text-xs text-zinc-500">{label}</span>
      <p className="mt-0.5 break-all rounded-lg border border-zinc-700 bg-zinc-800 p-2 font-mono text-xs text-zinc-300">
        {value || "—"}
      </p>
    </div>
  );
}

// ============================================================================
// Main Page
// ============================================================================

export default function Home() {
  // --- Wallet ---
  const { wallet, connect, disconnect, switchToPolkadotHub } = useWallet();
  const { stealthPayment, stealthVault } = useContracts(
    wallet.signer,
    SP_ADDR,
    SV_ADDR
  );

  // --- Keypair ---
  const [keyPair, setKeyPair] = useState<StealthKeyPair | null>(null);

  // --- Tab ---
  const [tab, setTab] = useState<
    "keys" | "send" | "scan" | "withdraw" | "vault"
  >("keys");

  // ===========================================================================
  // Key Generation & Registration
  // ===========================================================================
  const registerTx = useTx();
  const [registeredOnChain, setRegisteredOnChain] = useState(false);

  const handleGenerateKeys = useCallback(() => {
    const kp = generateStealthKeyPair();
    setKeyPair(kp);
    setRegisteredOnChain(false);
  }, []);

  const handleRegister = useCallback(async () => {
    if (!stealthPayment || !keyPair) return;
    await registerTx.execute(() =>
      stealthPayment.registerStealthMetaAddress(
        keyPair.metaAddress.spendingPubKey,
        keyPair.metaAddress.viewingPubKey
      )
    );
    setRegisteredOnChain(true);
  }, [stealthPayment, keyPair, registerTx]);

  // ===========================================================================
  // Send Stealth Payment
  // ===========================================================================
  const sendTx = useTx();
  const [recipientSpendKey, setRecipientSpendKey] = useState("");
  const [recipientViewKey, setRecipientViewKey] = useState("");
  const [sendAmount, setSendAmount] = useState("");
  const [paymentResult, setPaymentResult] = useState<StealthPaymentData | null>(
    null
  );

  const handleSendStealth = useCallback(async () => {
    if (!stealthPayment || !recipientSpendKey || !recipientViewKey || !sendAmount) return;

    const payment = computeStealthPayment({
      spendingPubKey: recipientSpendKey,
      viewingPubKey: recipientViewKey,
    });
    setPaymentResult(payment);

    const amountWei = ethers.parseEther(sendAmount);
    await sendTx.execute(() =>
      stealthPayment.sendNativeToStealth(
        payment.stealthAddress,
        payment.ephemeralPubKey,
        payment.viewTag,
        "0x",
        { value: amountWei }
      )
    );
  }, [stealthPayment, recipientSpendKey, recipientViewKey, sendAmount, sendTx]);

  // ===========================================================================
  // Scan for Payments
  // ===========================================================================
  const [scanResults, setScanResults] = useState<ScannedPayment[]>([]);
  const [scanning, setScanning] = useState(false);
  const [scanFromBlock, setScanFromBlock] = useState("0");

  const handleScan = useCallback(async () => {
    if (!wallet.provider || !keyPair || !SP_ADDR) return;
    setScanning(true);
    try {
      const results = await scanForPayments(
        wallet.provider,
        SP_ADDR,
        keyPair.viewingPrivateKey,
        keyPair.metaAddress.spendingPubKey,
        parseInt(scanFromBlock) || 0
      );
      setScanResults(results);
    } catch (err) {
      console.error("Scan failed:", err);
    }
    setScanning(false);
  }, [wallet.provider, keyPair, scanFromBlock]);

  // ===========================================================================
  // Withdraw from Stealth
  // ===========================================================================
  const withdrawTx = useTx();
  const [withdrawAddr, setWithdrawAddr] = useState("");
  const [withdrawTo, setWithdrawTo] = useState("");

  const handleWithdraw = useCallback(async () => {
    if (!stealthPayment || !withdrawAddr || !withdrawTo) return;
    await withdrawTx.execute(() =>
      stealthPayment.withdrawFromStealth(
        ethers.ZeroAddress, // native token
        withdrawTo
      )
    );
  }, [stealthPayment, withdrawAddr, withdrawTo, withdrawTx]);

  // ===========================================================================
  // Vault: Commitment Deposit
  // ===========================================================================
  const depositTx = useTx();
  const [depositAmount, setDepositAmount] = useState("");
  const [blindingFactor, setBlindingFactor] = useState("");
  const [commitmentHash, setCommitmentHash] = useState("");

  const handlePrepareDeposit = useCallback(() => {
    if (!wallet.address || !depositAmount) return;
    const bf = generateBlindingFactor();
    setBlindingFactor(bf);
    const commitment = computeCommitment(
      ethers.parseEther(depositAmount),
      bf,
      wallet.address
    );
    setCommitmentHash(commitment);
  }, [wallet.address, depositAmount]);

  const handleDeposit = useCallback(async () => {
    if (!stealthVault || !commitmentHash || !depositAmount) return;
    await depositTx.execute(() =>
      stealthVault.depositWithCommitment(commitmentHash, {
        value: ethers.parseEther(depositAmount),
      })
    );
  }, [stealthVault, commitmentHash, depositAmount, depositTx]);

  // ===========================================================================
  // Vault: Nullifier Withdrawal
  // ===========================================================================
  const vaultWithdrawTx = useTx();
  const [vwSecret, setVwSecret] = useState("");
  const [vwDepositIndex, setVwDepositIndex] = useState("");
  const [vwAmount, setVwAmount] = useState("");
  const [vwBlinding, setVwBlinding] = useState("");
  const [vwTo, setVwTo] = useState("");

  const handleVaultWithdraw = useCallback(async () => {
    if (!stealthVault || !vwSecret || !vwDepositIndex || !vwAmount || !vwBlinding || !vwTo)
      return;
    const nullifier = computeNullifier(vwSecret, parseInt(vwDepositIndex));
    await vaultWithdrawTx.execute(() =>
      stealthVault.withdrawWithNullifier(
        nullifier,
        parseInt(vwDepositIndex),
        ethers.parseEther(vwAmount),
        vwBlinding,
        vwTo
      )
    );
  }, [stealthVault, vwSecret, vwDepositIndex, vwAmount, vwBlinding, vwTo, vaultWithdrawTx]);

  // ===========================================================================
  // Stats
  // ===========================================================================
  const [stats, setStats] = useState({ announcements: "0", deposits: "0" });

  useEffect(() => {
    if (!stealthPayment || !stealthVault) return;
    (async () => {
      try {
        const [ann, dep] = await Promise.all([
          stealthPayment.getAnnouncementCount(),
          stealthVault.getDepositCount(),
        ]);
        setStats({
          announcements: ann.toString(),
          deposits: dep.toString(),
        });
      } catch {
        /* contract may not be deployed */
      }
    })();
  }, [stealthPayment, stealthVault]);

  // ===========================================================================
  // Render
  // ===========================================================================

  const tabs = [
    { id: "keys" as const, label: "Keys", icon: "🔑" },
    { id: "send" as const, label: "Send", icon: "📤" },
    { id: "scan" as const, label: "Scan", icon: "🔍" },
    { id: "withdraw" as const, label: "Withdraw", icon: "💰" },
    { id: "vault" as const, label: "Vault", icon: "🏦" },
  ];

  return (
    <div className="min-h-screen bg-gradient-to-b from-zinc-950 via-zinc-900 to-zinc-950 font-sans text-zinc-100">
      {/* Header */}
      <header className="border-b border-zinc-800 bg-zinc-950/80 backdrop-blur">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
          <div>
            <h1 className="text-xl font-bold tracking-tight">
              <span className="text-indigo-400">Omni</span>Shield
            </h1>
            <p className="text-xs text-zinc-500">
              Stealth Pay &amp; Cross-Chain Yield
            </p>
          </div>
          <div className="flex items-center gap-4">
            <StatusBadge
              connected={wallet.connected}
              chainId={wallet.chainId}
            />
            {wallet.connected ? (
              <div className="flex items-center gap-2">
                <span className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 font-mono text-xs text-zinc-300">
                  {wallet.address.slice(0, 6)}...{wallet.address.slice(-4)}
                </span>
                <span className="text-xs text-zinc-500">
                  {parseFloat(wallet.balance).toFixed(4)} WND
                </span>
                {wallet.chainId !== POLKADOT_HUB_TESTNET.chainId && (
                  <Btn variant="danger" onClick={switchToPolkadotHub}>
                    Switch Network
                  </Btn>
                )}
                <Btn variant="secondary" onClick={disconnect}>
                  Disconnect
                </Btn>
              </div>
            ) : (
              <Btn onClick={connect}>Connect Wallet</Btn>
            )}
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-5xl px-6 py-8">
        {/* Stats bar */}
        {wallet.connected && (SP_ADDR || SV_ADDR) && (
          <div className="mb-6 grid grid-cols-2 gap-4 sm:grid-cols-4">
            {[
              { label: "Announcements", value: stats.announcements },
              { label: "Vault Deposits", value: stats.deposits },
              {
                label: "StealthPayment",
                value: SP_ADDR ? `${SP_ADDR.slice(0, 8)}...` : "Not set",
              },
              {
                label: "StealthVault",
                value: SV_ADDR ? `${SV_ADDR.slice(0, 8)}...` : "Not set",
              },
            ].map((s) => (
              <div
                key={s.label}
                className="rounded-lg border border-zinc-800 bg-zinc-900/50 px-4 py-3"
              >
                <p className="text-xs text-zinc-500">{s.label}</p>
                <p className="font-mono text-sm font-medium text-zinc-200">
                  {s.value}
                </p>
              </div>
            ))}
          </div>
        )}

        {/* Tab navigation */}
        <nav className="mb-6 flex gap-1 rounded-lg border border-zinc-800 bg-zinc-900/50 p-1">
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`flex-1 rounded-md px-3 py-2 text-sm font-medium transition ${
                tab === t.id
                  ? "bg-indigo-600 text-white"
                  : "text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200"
              }`}
            >
              <span className="mr-1">{t.icon}</span>
              {t.label}
            </button>
          ))}
        </nav>

        {/* ================================================================= */}
        {/* Tab: Keys                                                          */}
        {/* ================================================================= */}
        {tab === "keys" && (
          <Card title="Stealth Key Management" icon="🔑">
            <p className="mb-4 text-sm text-zinc-400">
              Generate a stealth meta-address. Share the <strong>public keys</strong> with
              senders. Keep your private keys secret.
            </p>
            <div className="flex gap-3">
              <Btn onClick={handleGenerateKeys}>Generate New Keypair</Btn>
              {keyPair && !registeredOnChain && (
                <Btn
                  variant="secondary"
                  onClick={handleRegister}
                  disabled={!wallet.connected || registerTx.status.pending}
                >
                  {registerTx.status.pending
                    ? "Registering..."
                    : "Register On-Chain"}
                </Btn>
              )}
              {registeredOnChain && (
                <span className="flex items-center text-sm text-emerald-400">
                  ✓ Registered
                </span>
              )}
            </div>

            {keyPair && (
              <div className="mt-4 space-y-2">
                <div className="rounded-lg border border-indigo-500/30 bg-indigo-500/5 p-4">
                  <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-indigo-400">
                    Public Meta-Address (share with senders)
                  </p>
                  <MonoBox
                    label="Spending Public Key"
                    value={keyPair.metaAddress.spendingPubKey}
                  />
                  <MonoBox
                    label="Viewing Public Key"
                    value={keyPair.metaAddress.viewingPubKey}
                  />
                </div>
                <div className="rounded-lg border border-red-500/30 bg-red-500/5 p-4">
                  <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-red-400">
                    Private Keys (⚠️ KEEP SECRET)
                  </p>
                  <MonoBox
                    label="Spending Private Key"
                    value={keyPair.spendingPrivateKey}
                  />
                  <MonoBox
                    label="Viewing Private Key"
                    value={keyPair.viewingPrivateKey}
                  />
                </div>
              </div>
            )}

            <TxResult label="Register" {...registerTx.status} />
          </Card>
        )}

        {/* ================================================================= */}
        {/* Tab: Send                                                          */}
        {/* ================================================================= */}
        {tab === "send" && (
          <Card title="Send Stealth Payment" icon="📤">
            <p className="mb-4 text-sm text-zinc-400">
              Send native tokens to a stealth address. Only the recipient with the
              matching viewing key can discover this payment.
            </p>
            <div className="space-y-3">
              <Input
                label="Recipient Spending Public Key"
                value={recipientSpendKey}
                onChange={setRecipientSpendKey}
                placeholder="0x..."
              />
              <Input
                label="Recipient Viewing Public Key"
                value={recipientViewKey}
                onChange={setRecipientViewKey}
                placeholder="0x..."
              />
              <Input
                label="Amount (WND)"
                value={sendAmount}
                onChange={setSendAmount}
                placeholder="0.01"
                type="number"
              />
              <Btn
                onClick={handleSendStealth}
                disabled={
                  !wallet.connected ||
                  !recipientSpendKey ||
                  !recipientViewKey ||
                  !sendAmount ||
                  sendTx.status.pending
                }
              >
                {sendTx.status.pending ? "Sending..." : "Send Stealth Payment"}
              </Btn>
            </div>

            {paymentResult && (
              <div className="mt-4 rounded-lg border border-zinc-700 bg-zinc-800/50 p-4">
                <p className="mb-2 text-xs font-semibold text-zinc-400">
                  Payment Details
                </p>
                <MonoBox
                  label="Stealth Address"
                  value={paymentResult.stealthAddress}
                />
                <MonoBox
                  label="Ephemeral Public Key"
                  value={paymentResult.ephemeralPubKey}
                />
                <MonoBox
                  label="View Tag"
                  value={paymentResult.viewTag.toString()}
                />
              </div>
            )}

            <TxResult label="Send" {...sendTx.status} />
          </Card>
        )}

        {/* ================================================================= */}
        {/* Tab: Scan                                                          */}
        {/* ================================================================= */}
        {tab === "scan" && (
          <Card title="Scan for Received Payments" icon="🔍">
            <p className="mb-4 text-sm text-zinc-400">
              Scan on-chain announcements to discover stealth payments sent to
              your meta-address. Uses your viewing key for efficient filtering.
            </p>

            {!keyPair ? (
              <p className="text-sm text-amber-400">
                Generate keys first in the Keys tab.
              </p>
            ) : (
              <>
                <div className="flex items-end gap-3">
                  <div className="flex-1">
                    <Input
                      label="From Block"
                      value={scanFromBlock}
                      onChange={setScanFromBlock}
                      placeholder="0"
                      type="number"
                    />
                  </div>
                  <Btn
                    onClick={handleScan}
                    disabled={!wallet.connected || scanning}
                  >
                    {scanning ? "Scanning..." : "Scan Blockchain"}
                  </Btn>
                </div>

                {scanResults.length > 0 ? (
                  <div className="mt-4 space-y-2">
                    <p className="text-sm text-emerald-400">
                      Found {scanResults.length} payment(s):
                    </p>
                    {scanResults.map((r, i) => (
                      <div
                        key={i}
                        className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-3"
                      >
                        <p className="font-mono text-xs text-zinc-300">
                          {r.stealthAddress}
                        </p>
                        <p className="mt-1 text-xs text-zinc-500">
                          Block: {r.blockNumber} | View Tag: {r.viewTag}
                        </p>
                      </div>
                    ))}
                  </div>
                ) : (
                  !scanning && (
                    <p className="mt-4 text-sm text-zinc-500">
                      No payments found yet.
                    </p>
                  )
                )}
              </>
            )}
          </Card>
        )}

        {/* ================================================================= */}
        {/* Tab: Withdraw                                                      */}
        {/* ================================================================= */}
        {tab === "withdraw" && (
          <Card title="Withdraw from Stealth Address" icon="💰">
            <p className="mb-4 text-sm text-zinc-400">
              Withdraw funds from a stealth address you control. You must be
              connected with the stealth address&apos;s private key, or use
              relayer withdrawal.
            </p>
            <div className="space-y-3">
              <Input
                label="Stealth Address"
                value={withdrawAddr}
                onChange={setWithdrawAddr}
                placeholder="0x..."
              />
              <Input
                label="Withdraw To"
                value={withdrawTo}
                onChange={setWithdrawTo}
                placeholder="0x... (your main wallet)"
              />
              <Btn
                onClick={handleWithdraw}
                disabled={
                  !wallet.connected ||
                  !withdrawAddr ||
                  !withdrawTo ||
                  withdrawTx.status.pending
                }
              >
                {withdrawTx.status.pending
                  ? "Withdrawing..."
                  : "Withdraw Native"}
              </Btn>
            </div>
            <TxResult label="Withdraw" {...withdrawTx.status} />
          </Card>
        )}

        {/* ================================================================= */}
        {/* Tab: Vault                                                         */}
        {/* ================================================================= */}
        {tab === "vault" && (
          <div className="space-y-6">
            {/* -- Deposit -- */}
            <Card title="Commitment Deposit" icon="🏦">
              <p className="mb-4 text-sm text-zinc-400">
                Deposit funds with a cryptographic commitment. Only you can
                withdraw later using the blinding factor and nullifier.
              </p>
              <div className="space-y-3">
                <Input
                  label="Deposit Amount (WND)"
                  value={depositAmount}
                  onChange={(v) => {
                    setDepositAmount(v);
                    setCommitmentHash("");
                    setBlindingFactor("");
                  }}
                  placeholder="0.1"
                  type="number"
                />
                <div className="flex gap-3">
                  <Btn
                    variant="secondary"
                    onClick={handlePrepareDeposit}
                    disabled={!wallet.connected || !depositAmount}
                  >
                    Prepare Commitment
                  </Btn>
                  {commitmentHash && (
                    <Btn
                      onClick={handleDeposit}
                      disabled={!wallet.connected || depositTx.status.pending}
                    >
                      {depositTx.status.pending
                        ? "Depositing..."
                        : "Deposit"}
                    </Btn>
                  )}
                </div>

                {blindingFactor && (
                  <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-4">
                    <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-amber-400">
                      ⚠️ Save these — required for withdrawal
                    </p>
                    <MonoBox label="Blinding Factor" value={blindingFactor} />
                    <MonoBox label="Commitment" value={commitmentHash} />
                  </div>
                )}

                <TxResult label="Deposit" {...depositTx.status} />
              </div>
            </Card>

            {/* -- Vault Withdraw -- */}
            <Card title="Vault Withdrawal (Nullifier)" icon="🔓">
              <p className="mb-4 text-sm text-zinc-400">
                Withdraw from the vault using a nullifier. Requires your blinding
                factor and deposit details.
              </p>
              <div className="space-y-3">
                <Input
                  label="Withdrawal Secret"
                  value={vwSecret}
                  onChange={setVwSecret}
                  placeholder="0x... (your private secret)"
                />
                <div className="grid grid-cols-2 gap-3">
                  <Input
                    label="Deposit Index"
                    value={vwDepositIndex}
                    onChange={setVwDepositIndex}
                    placeholder="0"
                    type="number"
                  />
                  <Input
                    label="Amount (WND)"
                    value={vwAmount}
                    onChange={setVwAmount}
                    placeholder="0.1"
                    type="number"
                  />
                </div>
                <Input
                  label="Blinding Factor"
                  value={vwBlinding}
                  onChange={setVwBlinding}
                  placeholder="0x..."
                />
                <Input
                  label="Withdraw To"
                  value={vwTo}
                  onChange={setVwTo}
                  placeholder="0x..."
                />
                <Btn
                  onClick={handleVaultWithdraw}
                  disabled={
                    !wallet.connected ||
                    !vwSecret ||
                    !vwDepositIndex ||
                    !vwAmount ||
                    !vwBlinding ||
                    !vwTo ||
                    vaultWithdrawTx.status.pending
                  }
                >
                  {vaultWithdrawTx.status.pending
                    ? "Withdrawing..."
                    : "Withdraw via Nullifier"}
                </Btn>

                <TxResult label="Vault Withdraw" {...vaultWithdrawTx.status} />
              </div>
            </Card>
          </div>
        )}

        {/* Footer info */}
        <footer className="mt-12 border-t border-zinc-800 pt-6 text-center text-xs text-zinc-600">
          <p>
            OmniShield v1 — Polkadot Solidity Hackathon — Day 12-14: Stealth
            Address System
          </p>
          <p className="mt-1">
            Privacy-preserving stealth payments with EIP-5564 compatible
            announcements
          </p>
        </footer>
      </main>
    </div>
  );
}
