"use client";

import { ReactNode, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { cn } from "../lib/cn";

// ============================================================================
// Tooltip
// ============================================================================

export function Tooltip({ children, content }: { children: ReactNode; content: string }) {
  const [show, setShow] = useState(false);
  return (
    <span
      className="relative inline-flex"
      onMouseEnter={() => setShow(true)}
      onMouseLeave={() => setShow(false)}
    >
      {children}
      <AnimatePresence>
        {show && (
          <motion.span
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: 4 }}
            className="absolute bottom-full left-1/2 z-50 mb-2 -translate-x-1/2 whitespace-nowrap rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-xs text-zinc-300 shadow-xl"
          >
            {content}
          </motion.span>
        )}
      </AnimatePresence>
    </span>
  );
}

// ============================================================================
// Status Stepper
// ============================================================================

interface StepperStep {
  label: string;
  done: boolean;
  active: boolean;
}

export function StatusStepper({ steps }: { steps: StepperStep[] }) {
  return (
    <div className="flex items-center gap-1">
      {steps.map((s, i) => (
        <div key={i} className="flex items-center gap-1">
          <div
            className={cn(
              "flex h-7 items-center gap-1.5 rounded-full px-3 text-xs font-medium transition-all",
              s.done
                ? "bg-emerald-500/20 text-emerald-400"
                : s.active
                  ? "bg-indigo-500/20 text-indigo-400 ring-1 ring-indigo-500/40"
                  : "bg-zinc-800 text-zinc-500"
            )}
          >
            {s.done ? "✓" : s.active ? "●" : "○"}
            <span>{s.label}</span>
          </div>
          {i < steps.length - 1 && (
            <div
              className={cn(
                "h-px w-4",
                s.done ? "bg-emerald-500/40" : "bg-zinc-700"
              )}
            />
          )}
        </div>
      ))}
    </div>
  );
}

// ============================================================================
// Stat Card
// ============================================================================

export function StatCard({
  label,
  value,
  icon,
  trend,
  tooltip,
}: {
  label: string;
  value: string;
  icon?: ReactNode;
  trend?: { value: string; positive: boolean };
  tooltip?: string;
}) {
  const inner = (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900/60 p-4 backdrop-blur transition hover:border-zinc-700">
      <div className="flex items-start justify-between">
        <p className="text-xs font-medium text-zinc-500">{label}</p>
        {icon && <span className="text-zinc-600">{icon}</span>}
      </div>
      <p className="mt-1 text-2xl font-bold tracking-tight text-zinc-100">{value}</p>
      {trend && (
        <p
          className={cn(
            "mt-1 text-xs font-medium",
            trend.positive ? "text-emerald-400" : "text-red-400"
          )}
        >
          {trend.positive ? "↑" : "↓"} {trend.value}
        </p>
      )}
    </div>
  );

  if (tooltip) return <Tooltip content={tooltip}>{inner}</Tooltip>;
  return inner;
}

// ============================================================================
// Glass Card
// ============================================================================

export function GlassCard({
  children,
  className,
  title,
  icon,
  action,
}: {
  children: ReactNode;
  className?: string;
  title?: string;
  icon?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <motion.div
      layout
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.3 }}
      className={cn(
        "rounded-xl border border-zinc-800 bg-zinc-900/60 p-6 backdrop-blur",
        className
      )}
    >
      {(title || action) && (
        <div className="mb-4 flex items-center justify-between">
          <div className="flex items-center gap-2">
            {icon && <span className="text-lg">{icon}</span>}
            {title && (
              <h3 className="text-base font-semibold text-zinc-100">{title}</h3>
            )}
          </div>
          {action}
        </div>
      )}
      {children}
    </motion.div>
  );
}

// ============================================================================
// Page Wrapper with Fade
// ============================================================================

export function PageTransition({ children }: { children: ReactNode }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -8 }}
      transition={{ duration: 0.25, ease: "easeOut" }}
    >
      {children}
    </motion.div>
  );
}

// ============================================================================
// Badge
// ============================================================================

const badgeVariants = {
  success: "bg-emerald-500/15 text-emerald-400 border-emerald-500/30",
  warning: "bg-amber-500/15 text-amber-400 border-amber-500/30",
  danger: "bg-red-500/15 text-red-400 border-red-500/30",
  info: "bg-indigo-500/15 text-indigo-400 border-indigo-500/30",
  neutral: "bg-zinc-800 text-zinc-400 border-zinc-700",
};

export function Badge({
  children,
  variant = "neutral",
}: {
  children: ReactNode;
  variant?: keyof typeof badgeVariants;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium",
        badgeVariants[variant]
      )}
    >
      {children}
    </span>
  );
}

// ============================================================================
// Button
// ============================================================================

const btnVariants = {
  primary: "bg-indigo-600 hover:bg-indigo-500 text-white shadow-lg shadow-indigo-500/10",
  secondary: "bg-zinc-800 hover:bg-zinc-700 text-zinc-100 border border-zinc-700",
  danger: "bg-red-600/80 hover:bg-red-500 text-white",
  ghost: "bg-transparent hover:bg-zinc-800 text-zinc-400 hover:text-zinc-200",
};

export function Button({
  children,
  onClick,
  disabled = false,
  variant = "primary",
  size = "md",
  className: cls,
}: {
  children: ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  variant?: keyof typeof btnVariants;
  size?: "sm" | "md" | "lg";
  className?: string;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-lg font-medium transition disabled:cursor-not-allowed disabled:opacity-40",
        btnVariants[variant],
        size === "sm" && "px-3 py-1.5 text-xs",
        size === "md" && "px-4 py-2 text-sm",
        size === "lg" && "px-6 py-3 text-base",
        cls
      )}
    >
      {children}
    </button>
  );
}

// ============================================================================
// Input
// ============================================================================

export function Input({
  label,
  value,
  onChange,
  placeholder,
  type = "text",
  disabled = false,
  className: cls,
}: {
  label?: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  type?: string;
  disabled?: boolean;
  className?: string;
}) {
  return (
    <label className={cn("block", cls)}>
      {label && <span className="mb-1 block text-sm text-zinc-400">{label}</span>}
      <input
        type={type}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        disabled={disabled}
        className="w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-zinc-100 placeholder-zinc-600 transition focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500/30 disabled:opacity-50"
      />
    </label>
  );
}

// ============================================================================
// MonoBox (read-only copyable field)
// ============================================================================

export function MonoBox({ label, value }: { label: string; value: string }) {
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
// Transaction Result
// ============================================================================

export function TxResult({
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
    <motion.div
      initial={{ opacity: 0, height: 0 }}
      animate={{ opacity: 1, height: "auto" }}
      className={cn(
        "mt-3 overflow-hidden rounded-lg border p-3 text-sm",
        error
          ? "border-red-500/40 bg-red-500/10 text-red-300"
          : success
            ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-300"
            : "border-zinc-700 bg-zinc-800/50 text-zinc-400"
      )}
    >
      <p className="font-medium">
        {pending ? `${label} — Pending...` : error ? `${label} — Failed` : `${label} — Success`}
      </p>
      {hash && (
        <a
          href={`https://blockscout-testnet.polkadot.io/tx/${hash}`}
          target="_blank"
          rel="noopener noreferrer"
          className="mt-1 block truncate font-mono text-xs opacity-70 hover:underline"
        >
          tx: {hash}
        </a>
      )}
      {error && <p className="mt-1 text-xs opacity-70">{error}</p>}
    </motion.div>
  );
}

// ============================================================================
// Empty State
// ============================================================================

export function EmptyState({ icon, title, description }: { icon: ReactNode; title: string; description: string }) {
  return (
    <div className="flex flex-col items-center justify-center py-16 text-center">
      <div className="mb-4 text-4xl text-zinc-600">{icon}</div>
      <h3 className="text-lg font-semibold text-zinc-400">{title}</h3>
      <p className="mt-1 max-w-sm text-sm text-zinc-600">{description}</p>
    </div>
  );
}

// ============================================================================
// Pulse Dot (for live indicators)
// ============================================================================

export function PulseDot({ color = "emerald" }: { color?: "emerald" | "amber" | "red" | "indigo" }) {
  const colors = {
    emerald: "bg-emerald-400",
    amber: "bg-amber-400",
    red: "bg-red-400",
    indigo: "bg-indigo-400",
  };
  return (
    <span className="relative flex h-2.5 w-2.5">
      <span className={cn("absolute inline-flex h-full w-full animate-ping rounded-full opacity-75", colors[color])} />
      <span className={cn("relative inline-flex h-2.5 w-2.5 rounded-full", colors[color])} />
    </span>
  );
}

// ============================================================================
// Data Table
// ============================================================================

interface Column<T> {
  header: string;
  accessor: (row: T) => ReactNode;
  className?: string;
}

export function DataTable<T>({
  columns,
  data,
  onRowClick,
  emptyMessage = "No data",
}: {
  columns: Column<T>[];
  data: T[];
  onRowClick?: (row: T) => void;
  emptyMessage?: string;
}) {
  if (data.length === 0) {
    return <p className="py-8 text-center text-sm text-zinc-500">{emptyMessage}</p>;
  }
  return (
    <div className="overflow-x-auto">
      <table className="w-full">
        <thead>
          <tr className="border-b border-zinc-800 text-left">
            {columns.map((c, i) => (
              <th key={i} className={cn("px-4 py-3 text-xs font-medium uppercase tracking-wider text-zinc-500", c.className)}>
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {data.map((row, i) => (
            <tr
              key={i}
              onClick={() => onRowClick?.(row)}
              className={cn(
                "border-b border-zinc-800/50 transition",
                onRowClick && "cursor-pointer hover:bg-zinc-800/30"
              )}
            >
              {columns.map((c, j) => (
                <td key={j} className={cn("px-4 py-3 text-sm text-zinc-300", c.className)}>
                  {c.accessor(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
