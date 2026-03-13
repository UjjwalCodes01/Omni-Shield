"use client";

import { useState, useCallback, useEffect } from "react";
import { ethers } from "ethers";
import {
  POLKADOT_HUB_TESTNET,
  STEALTH_PAYMENT_ABI,
  STEALTH_VAULT_ABI,
} from "./stealth";

// ============================================================================
// Types
// ============================================================================

export interface WalletState {
  connected: boolean;
  address: string;
  balance: string;
  chainId: number;
  provider: ethers.BrowserProvider | null;
  signer: ethers.Signer | null;
}

export interface TxStatus {
  pending: boolean;
  hash: string;
  error: string;
  success: boolean;
}

const CUSTOM_ERROR_MESSAGES: Record<string, string> = {
  "0x9c8d2cd2": "Invalid recipient address.",
  "0x692bfa7f": "Escrow is not active.",
  "0xce8c1048": "Only the escrow depositor can perform this action.",
  "0xeafacd94": "Invalid release condition data.",
  "0x5b3d0edd": "Escrow has not expired yet.",
  "0x96ec8e54": "Deposit is below the contract minimum.",
  "0x30a79c2f": "No active yield source is available.",
  "0xb1eba972": "Selected yield source is not active.",
  "0x1e074cd7": "Selected yield source is at capacity.",
  "0x2c295855": "Invalid yield source ID.",
  "0x149fb2de": "Only the route owner can perform this action.",
  "0x37164df9": "Yield route is not active.",
};

function decodeTxError(err: unknown): string {
  if (!(err instanceof Error)) return "Transaction failed";

  const anyErr = err as Error & {
    data?: string;
    info?: { error?: { data?: string } };
  };

  const message = err.message || "Transaction failed";
  const candidateData =
    (typeof anyErr.data === "string" && anyErr.data) ||
    (typeof anyErr.info?.error?.data === "string" && anyErr.info.error.data) ||
    "";

  const selectorFromData = candidateData.startsWith("0x") ? candidateData.slice(0, 10) : "";
  const selectorFromMsg = (message.match(/0x[a-fA-F0-9]{8}/) ?? [])[0]?.toLowerCase() ?? "";
  const selector = (selectorFromData || selectorFromMsg || "").toLowerCase();

  if (selector && CUSTOM_ERROR_MESSAGES[selector]) {
    return CUSTOM_ERROR_MESSAGES[selector];
  }

  return message;
}

// ============================================================================
// Wallet Hook
// ============================================================================

export function useWallet() {
  const [wallet, setWallet] = useState<WalletState>({
    connected: false,
    address: "",
    balance: "0",
    chainId: 0,
    provider: null,
    signer: null,
  });

  const connect = useCallback(async () => {
    if (typeof window === "undefined" || !window.ethereum) {
      throw new Error("MetaMask not detected");
    }

    const provider = new ethers.BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);
    const signer = await provider.getSigner();
    const address = await signer.getAddress();
    const balance = ethers.formatEther(await provider.getBalance(address));
    const network = await provider.getNetwork();

    setWallet({
      connected: true,
      address,
      balance,
      chainId: Number(network.chainId),
      provider,
      signer,
    });
  }, []);

  const switchToPolkadotHub = useCallback(async () => {
    if (!window.ethereum) return;
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [
          { chainId: "0x" + POLKADOT_HUB_TESTNET.chainId.toString(16) },
        ],
      });
    } catch (switchError: unknown) {
      const err = switchError as { code?: number };
      if (err.code === 4902) {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId:
                "0x" + POLKADOT_HUB_TESTNET.chainId.toString(16),
              chainName: POLKADOT_HUB_TESTNET.name,
              rpcUrls: [POLKADOT_HUB_TESTNET.rpcUrl],
              nativeCurrency: {
                name: "WND",
                symbol: "WND",
                decimals: 18,
              },
            },
          ],
        });
      }
    }
  }, []);

  const disconnect = useCallback(() => {
    setWallet({
      connected: false,
      address: "",
      balance: "0",
      chainId: 0,
      provider: null,
      signer: null,
    });
  }, []);

  // Listen for account/chain changes
  useEffect(() => {
    if (typeof window === "undefined" || !window.ethereum) return;

    const handleAccountsChanged = () => {
      if (wallet.connected) connect();
    };
    const handleChainChanged = () => {
      if (wallet.connected) connect();
    };

    window.ethereum.on("accountsChanged", handleAccountsChanged);
    window.ethereum.on("chainChanged", handleChainChanged);
    return () => {
      window.ethereum?.removeListener(
        "accountsChanged",
        handleAccountsChanged
      );
      window.ethereum?.removeListener("chainChanged", handleChainChanged);
    };
  }, [wallet.connected, connect]);

  return { wallet, connect, disconnect, switchToPolkadotHub };
}

// ============================================================================
// Contract Hook
// ============================================================================

export function useContracts(
  signer: ethers.Signer | null,
  stealthPaymentAddr: string,
  stealthVaultAddr: string
) {
  const stealthPayment =
    signer && stealthPaymentAddr
      ? new ethers.Contract(stealthPaymentAddr, STEALTH_PAYMENT_ABI, signer)
      : null;

  const stealthVault =
    signer && stealthVaultAddr
      ? new ethers.Contract(stealthVaultAddr, STEALTH_VAULT_ABI, signer)
      : null;

  return { stealthPayment, stealthVault };
}

// ============================================================================
// Transaction Hook
// ============================================================================

export function useTx() {
  const [status, setStatus] = useState<TxStatus>({
    pending: false,
    hash: "",
    error: "",
    success: false,
  });

  const reset = useCallback(() => {
    setStatus({ pending: false, hash: "", error: "", success: false });
  }, []);

  const fail = useCallback((error: string) => {
    setStatus({ pending: false, hash: "", error, success: false });
  }, []);

  const execute = useCallback(
    async (txFn: () => Promise<ethers.TransactionResponse>) => {
      setStatus({ pending: true, hash: "", error: "", success: false });
      try {
        const tx = await txFn();
        setStatus((s) => ({ ...s, hash: tx.hash }));
        await tx.wait();
        setStatus({ pending: false, hash: tx.hash, error: "", success: true });
        return tx.hash;
      } catch (err: unknown) {
        const msg = decodeTxError(err);
        setStatus({ pending: false, hash: "", error: msg, success: false });
        return null;
      }
    },
    []
  );

  return { status, execute, reset, fail };
}

// ============================================================================
// MetaMask type augmentation
// ============================================================================

declare global {
  interface Window {
    ethereum?: ethers.Eip1193Provider & {
      on: (event: string, handler: (...args: unknown[]) => void) => void;
      removeListener: (
        event: string,
        handler: (...args: unknown[]) => void
      ) => void;
      request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
    };
  }
}
