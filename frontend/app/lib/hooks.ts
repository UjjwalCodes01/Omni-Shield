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
        const msg =
          err instanceof Error ? err.message : "Transaction failed";
        setStatus({ pending: false, hash: "", error: msg, success: false });
        return null;
      }
    },
    []
  );

  return { status, execute, reset };
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
