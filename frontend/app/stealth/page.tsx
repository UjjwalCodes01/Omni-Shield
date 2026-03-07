"use client";

import { useEffect, useState, useCallback } from "react";
import { ethers } from "ethers";
import { Key, Send, Eye, EyeOff, ShieldCheck, Copy, CheckCircle2, AlertTriangle } from "lucide-react";
import { useWalletContext } from "../components/wallet-provider";
import {
  GlassCard, Badge, Button, Input, PageTransition, MonoBox,
  StatusStepper, TxResult, EmptyState,
} from "../components/ui";
import { CONTRACT_ADDRESSES } from "../lib/contracts";
import {
  POLKADOT_HUB_TESTNET, STEALTH_PAYMENT_ABI, STEALTH_VAULT_ABI,
  generateStealthKeyPair, computeStealthPayment, computeCommitment,
  generateBlindingFactor, computeNullifier,
  type StealthKeyPair, type StealthPaymentData,
} from "../lib/stealth";
import { useTx } from "../lib/hooks";

// ============================================================================
// Page
// ============================================================================

export default function StealthVaultPage() {
  const { wallet } = useWalletContext();

  // Key Management
  const [keyPair, setKeyPair] = useState<StealthKeyPair | null>(null);
  const [registeredOnChain, setRegisteredOnChain] = useState(false);
  const [showPrivate, setShowPrivate] = useState(false);
  const [copied, setCopied] = useState("");
  const registerTx = useTx();

  // Send Stealth Payment
  const [recipientSpendKey, setRecipientSpendKey] = useState("");
  const [recipientViewKey, setRecipientViewKey] = useState("");
  const [sendAmount, setSendAmount] = useState("");
  const [paymentResult, setPaymentResult] = useState<StealthPaymentData | null>(null);
  const sendTx = useTx();

  // Vault Deposit
  const [depositAmount, setDepositAmount] = useState("");
  const [blindingFactor, setBlindingFactor] = useState("");
  const [commitmentHash, setCommitmentHash] = useState("");
  const depositTx = useTx();

  // Vault Withdraw
  const [vwSecret, setVwSecret] = useState("");
  const [vwDepositIndex, setVwDepositIndex] = useState("");
  const [vwAmount, setVwAmount] = useState("");
  const [vwBlinding, setVwBlinding] = useState("");
  const [vwTo, setVwTo] = useState("");
  const vaultWithdrawTx = useTx();

  // Stats
  const [stats, setStats] = useState({ announcements: "0", deposits: "0" });
  useEffect(() => {
    (async () => {
      try {
        const provider = new ethers.JsonRpcProvider(POLKADOT_HUB_TESTNET.rpcUrl);
        const sp = new ethers.Contract(CONTRACT_ADDRESSES.stealthPayment, STEALTH_PAYMENT_ABI, provider);
        const sv = new ethers.Contract(CONTRACT_ADDRESSES.stealthVault, STEALTH_VAULT_ABI, provider);
        const [ann, dep] = await Promise.all([
          sp.getAnnouncementCount().catch(() => BigInt(0)),
          sv.getDepositCount().catch(() => BigInt(0)),
        ]);
        setStats({ announcements: ann.toString(), deposits: dep.toString() });
      } catch { /* skip */ }
    })();
  }, []);

  const copyToClipboard = useCallback((text: string, label: string) => {
    navigator.clipboard.writeText(text);
    setCopied(label);
    setTimeout(() => setCopied(""), 2000);
  }, []);

  const handleGenerateKeys = useCallback(() => {
    setKeyPair(generateStealthKeyPair());
    setRegisteredOnChain(false);
  }, []);

  const handleRegister = useCallback(async () => {
    if (!wallet.signer || !keyPair) return;
    const sp = new ethers.Contract(CONTRACT_ADDRESSES.stealthPayment, STEALTH_PAYMENT_ABI, wallet.signer);
    await registerTx.execute(() =>
      sp.registerStealthMetaAddress(keyPair.metaAddress.spendingPubKey, keyPair.metaAddress.viewingPubKey)
    );
    setRegisteredOnChain(true);
  }, [wallet.signer, keyPair, registerTx]);

  const handleSend = useCallback(async () => {
    if (!wallet.signer || !recipientSpendKey || !recipientViewKey || !sendAmount) return;
    const payment = computeStealthPayment({ spendingPubKey: recipientSpendKey, viewingPubKey: recipientViewKey });
    setPaymentResult(payment);
    const sp = new ethers.Contract(CONTRACT_ADDRESSES.stealthPayment, STEALTH_PAYMENT_ABI, wallet.signer);
    await sendTx.execute(() =>
      sp.sendNativeToStealth(payment.stealthAddress, payment.ephemeralPubKey, payment.viewTag, "0x", {
        value: ethers.parseEther(sendAmount),
      })
    );
  }, [wallet.signer, recipientSpendKey, recipientViewKey, sendAmount, sendTx]);

  const handlePrepareDeposit = useCallback(() => {
    if (!wallet.address || !depositAmount) return;
    const bf = generateBlindingFactor();
    setBlindingFactor(bf);
    setCommitmentHash(computeCommitment(ethers.parseEther(depositAmount), bf, wallet.address));
  }, [wallet.address, depositAmount]);

  const handleDeposit = useCallback(async () => {
    if (!wallet.signer || !commitmentHash || !depositAmount) return;
    const sv = new ethers.Contract(CONTRACT_ADDRESSES.stealthVault, STEALTH_VAULT_ABI, wallet.signer);
    await depositTx.execute(() => sv.depositWithCommitment(commitmentHash, { value: ethers.parseEther(depositAmount) }));
  }, [wallet.signer, commitmentHash, depositAmount, depositTx]);

  const handleVaultWithdraw = useCallback(async () => {
    if (!wallet.signer || !vwSecret || !vwDepositIndex || !vwAmount || !vwBlinding || !vwTo) return;
    const nullifier = computeNullifier(vwSecret, parseInt(vwDepositIndex));
    const sv = new ethers.Contract(CONTRACT_ADDRESSES.stealthVault, STEALTH_VAULT_ABI, wallet.signer);
    await vaultWithdrawTx.execute(() =>
      sv.withdrawWithNullifier(nullifier, parseInt(vwDepositIndex), ethers.parseEther(vwAmount), vwBlinding, vwTo)
    );
  }, [wallet.signer, vwSecret, vwDepositIndex, vwAmount, vwBlinding, vwTo, vaultWithdrawTx]);

  const CopyBtn = ({ text, label }: { text: string; label: string }) => (
    <button onClick={() => copyToClipboard(text, label)} className="ml-2 text-zinc-500 hover:text-zinc-300 transition">
      {copied === label ? <CheckCircle2 size={14} className="text-emerald-400" /> : <Copy size={14} />}
    </button>
  );

  return (
    <PageTransition>
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-100">Stealth Vault</h1>
          <p className="mt-1 text-sm text-zinc-500">
            EIP-5564 stealth payments + commitment-based privacy vault — {stats.announcements} announcements, {stats.deposits} vault deposits
          </p>
        </div>

        {/* Key Management */}
        <GlassCard title="Stealth Key Management" icon={<Key size={18} className="text-indigo-400" />}>
          <StatusStepper steps={[
            { label: "Generate", done: !!keyPair, active: !keyPair },
            { label: "Register", done: registeredOnChain, active: !!keyPair && !registeredOnChain },
            { label: "Ready", done: registeredOnChain, active: false },
          ]} />
          <p className="mt-3 text-sm text-zinc-400">
            Generate a stealth meta-address. Share the <span className="text-zinc-200">public keys</span> with senders. Keep private keys secret.
          </p>
          <div className="mt-4 flex flex-wrap gap-3">
            <Button onClick={handleGenerateKeys} variant="secondary">
              <Key size={14} /> Generate New Keypair
            </Button>
            {keyPair && !registeredOnChain && (
              <Button onClick={handleRegister} disabled={!wallet.connected || registerTx.status.pending}>
                {registerTx.status.pending ? "Registering..." : "Register On-Chain"}
              </Button>
            )}
            {registeredOnChain && <Badge variant="success">✓ Registered</Badge>}
          </div>

          {keyPair && (
            <div className="mt-4 space-y-3">
              <div className="rounded-lg border border-indigo-500/30 bg-indigo-500/5 p-4">
                <div className="flex items-center justify-between">
                  <p className="text-xs font-semibold uppercase tracking-wide text-indigo-400">Public Meta-Address (share with senders)</p>
                </div>
                <div className="mt-2 space-y-1">
                  <div className="flex items-center">
                    <span className="flex-1"><MonoBox label="Spending Public Key" value={keyPair.metaAddress.spendingPubKey} /></span>
                    <CopyBtn text={keyPair.metaAddress.spendingPubKey} label="spend-pub" />
                  </div>
                  <div className="flex items-center">
                    <span className="flex-1"><MonoBox label="Viewing Public Key" value={keyPair.metaAddress.viewingPubKey} /></span>
                    <CopyBtn text={keyPair.metaAddress.viewingPubKey} label="view-pub" />
                  </div>
                </div>
              </div>
              <div className="rounded-lg border border-red-500/30 bg-red-500/5 p-4">
                <div className="flex items-center justify-between">
                  <p className="text-xs font-semibold uppercase tracking-wide text-red-400">
                    <AlertTriangle size={12} className="mr-1 inline" /> Private Keys — KEEP SECRET
                  </p>
                  <button onClick={() => setShowPrivate(!showPrivate)} className="text-zinc-500 hover:text-zinc-300 transition">
                    {showPrivate ? <EyeOff size={14} /> : <Eye size={14} />}
                  </button>
                </div>
                {showPrivate && (
                  <div className="mt-2 space-y-1">
                    <MonoBox label="Spending Private Key" value={keyPair.spendingPrivateKey} />
                    <MonoBox label="Viewing Private Key" value={keyPair.viewingPrivateKey} />
                  </div>
                )}
              </div>
            </div>
          )}
          <TxResult label="Register" {...registerTx.status} />
        </GlassCard>

        <div className="grid gap-6 lg:grid-cols-2">
          {/* Send Stealth Payment */}
          <GlassCard title="Send Stealth Payment" icon={<Send size={18} className="text-purple-400" />}>
            <StatusStepper steps={[
              { label: "Recipient", done: !!recipientSpendKey && !!recipientViewKey, active: !recipientSpendKey },
              { label: "Amount", done: !!sendAmount, active: !!recipientSpendKey && !sendAmount },
              { label: "Send", done: sendTx.status.success, active: !!sendAmount },
            ]} />
            <div className="mt-4 space-y-3">
              <Input label="Recipient Spending Public Key" value={recipientSpendKey} onChange={setRecipientSpendKey} placeholder="0x..." />
              <Input label="Recipient Viewing Public Key" value={recipientViewKey} onChange={setRecipientViewKey} placeholder="0x..." />
              <Input label="Amount (WND)" value={sendAmount} onChange={setSendAmount} placeholder="0.01" type="number" />
              <Button onClick={handleSend} disabled={!wallet.connected || !recipientSpendKey || !recipientViewKey || !sendAmount || sendTx.status.pending}>
                <Send size={14} /> {sendTx.status.pending ? "Sending..." : "Send Stealth Payment"}
              </Button>
            </div>
            {paymentResult && (
              <div className="mt-4 rounded-lg border border-zinc-700 bg-zinc-800/50 p-4">
                <p className="mb-2 text-xs font-semibold text-zinc-400">Payment Details</p>
                <MonoBox label="Stealth Address" value={paymentResult.stealthAddress} />
                <MonoBox label="Ephemeral Public Key" value={paymentResult.ephemeralPubKey} />
                <MonoBox label="View Tag" value={paymentResult.viewTag.toString()} />
              </div>
            )}
            <TxResult label="Send" {...sendTx.status} />
          </GlassCard>

          {/* Commitment Vault */}
          <div className="space-y-6">
            <GlassCard title="Commitment Deposit" icon={<ShieldCheck size={18} className="text-emerald-400" />}>
              <div className="space-y-3">
                <Input
                  label="Deposit Amount (WND)"
                  value={depositAmount}
                  onChange={(v) => { setDepositAmount(v); setCommitmentHash(""); setBlindingFactor(""); }}
                  placeholder="0.1"
                  type="number"
                />
                <div className="flex gap-3">
                  <Button variant="secondary" onClick={handlePrepareDeposit} disabled={!wallet.connected || !depositAmount}>
                    Prepare Commitment
                  </Button>
                  {commitmentHash && (
                    <Button onClick={handleDeposit} disabled={!wallet.connected || depositTx.status.pending}>
                      {depositTx.status.pending ? "Depositing..." : "Deposit"}
                    </Button>
                  )}
                </div>
                {blindingFactor && (
                  <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-3">
                    <p className="text-xs font-semibold text-amber-400">⚠️ Save these — required for withdrawal</p>
                    <MonoBox label="Blinding Factor" value={blindingFactor} />
                    <MonoBox label="Commitment" value={commitmentHash} />
                  </div>
                )}
                <TxResult label="Deposit" {...depositTx.status} />
              </div>
            </GlassCard>

            <GlassCard title="Vault Withdrawal (Nullifier)" icon={<Key size={18} className="text-amber-400" />}>
              <div className="space-y-3">
                <Input label="Withdrawal Secret" value={vwSecret} onChange={setVwSecret} placeholder="0x..." />
                <div className="grid grid-cols-2 gap-3">
                  <Input label="Deposit Index" value={vwDepositIndex} onChange={setVwDepositIndex} placeholder="0" type="number" />
                  <Input label="Amount (WND)" value={vwAmount} onChange={setVwAmount} placeholder="0.1" type="number" />
                </div>
                <Input label="Blinding Factor" value={vwBlinding} onChange={setVwBlinding} placeholder="0x..." />
                <Input label="Withdraw To" value={vwTo} onChange={setVwTo} placeholder="0x..." />
                <Button onClick={handleVaultWithdraw} disabled={!wallet.connected || !vwSecret || !vwDepositIndex || !vwAmount || !vwBlinding || !vwTo || vaultWithdrawTx.status.pending}>
                  {vaultWithdrawTx.status.pending ? "Withdrawing..." : "Withdraw via Nullifier"}
                </Button>
                <TxResult label="Vault Withdraw" {...vaultWithdrawTx.status} />
              </div>
            </GlassCard>
          </div>
        </div>
      </div>
    </PageTransition>
  );
}
