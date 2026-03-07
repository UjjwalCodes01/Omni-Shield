"use client";

import { createContext, useContext, ReactNode } from "react";
import { useWallet, type WalletState } from "../lib/hooks";
import { POLKADOT_HUB_TESTNET } from "../lib/stealth";

interface WalletContextValue {
  wallet: WalletState;
  connect: () => Promise<void>;
  disconnect: () => void;
  switchToPolkadotHub: () => Promise<void>;
  isCorrectChain: boolean;
}

const WalletContext = createContext<WalletContextValue | null>(null);

export function WalletProvider({ children }: { children: ReactNode }) {
  const { wallet, connect, disconnect, switchToPolkadotHub } = useWallet();
  const isCorrectChain = wallet.chainId === POLKADOT_HUB_TESTNET.chainId;

  return (
    <WalletContext.Provider
      value={{ wallet, connect, disconnect, switchToPolkadotHub, isCorrectChain }}
    >
      {children}
    </WalletContext.Provider>
  );
}

export function useWalletContext() {
  const ctx = useContext(WalletContext);
  if (!ctx) throw new Error("useWalletContext must be used within WalletProvider");
  return ctx;
}
