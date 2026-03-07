import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { WalletProvider } from "./components/wallet-provider";
import { DashboardLayout } from "./components/dashboard-layout";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "OmniShield — Stealth Pay & Cross-Chain Yield",
  description:
    "Privacy-preserving stealth payments and cross-chain yield optimization on Polkadot",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="dark">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        <WalletProvider>
          <DashboardLayout>{children}</DashboardLayout>
        </WalletProvider>
      </body>
    </html>
  );
}
