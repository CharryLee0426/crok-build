"use client";

import Link from "next/link";
import { useEffect, useId, useRef, useState } from "react";
import type { ButtonHTMLAttributes, ReactNode } from "react";
import { projectHue, projectInitials } from "@/lib/format";
import { useI18n } from "./I18nProvider";
import { MoreIcon, SpinnerIcon } from "./icons";

type ButtonTone = "primary" | "secondary" | "ghost" | "danger" | "dangerGhost";
type ButtonSize = "sm" | "md" | "lg";

const BUTTON_TONES: Record<ButtonTone, string> = {
  primary: "bg-accent text-accent-fg hover:bg-accent-hover",
  secondary: "bg-surface text-fg border border-line hover:bg-surface-2",
  ghost: "text-fg hover:bg-hover",
  danger: "bg-danger-soft text-danger hover:brightness-95",
  dangerGhost: "text-danger hover:bg-danger-soft",
};
const BUTTON_SIZES: Record<ButtonSize, string> = {
  sm: "h-8 px-3 text-[13px]",
  md: "h-10 px-4 text-sm",
  lg: "h-12 px-6 text-[15px]",
};

function buttonClass(tone: ButtonTone, size: ButtonSize, extra: string) {
  return `inline-flex items-center justify-center gap-2 rounded-full font-medium transition-colors disabled:cursor-not-allowed disabled:opacity-50 ${BUTTON_TONES[tone]} ${BUTTON_SIZES[size]} ${extra}`;
}

export function Button({
  tone = "secondary",
  size = "md",
  busy,
  className = "",
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { tone?: ButtonTone; size?: ButtonSize; busy?: boolean }) {
  return (
    <button type="button" {...rest} disabled={rest.disabled || busy} className={buttonClass(tone, size, className)}>
      {busy ? <SpinnerIcon size={16} /> : null}
      {children}
    </button>
  );
}

/** A link that looks like a button (never a <button> inside an <a>). */
export function ButtonLink({
  href,
  tone = "secondary",
  size = "md",
  className = "",
  children,
}: {
  href: string;
  tone?: ButtonTone;
  size?: ButtonSize;
  className?: string;
  children: ReactNode;
}) {
  return (
    <Link href={href} className={buttonClass(tone, size, className)}>
      {children}
    </Link>
  );
}

export function IconButton({
  label,
  className = "",
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { label: string }) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      {...rest}
      className={`inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-muted transition-colors hover:bg-hover hover:text-fg disabled:opacity-40 ${className}`}
    >
      {children}
    </button>
  );
}

/** A project avatar: initials of the folder, a hue per folder, and Telegram's online dot. */
export function ProjectAvatar({
  cwd,
  title,
  online,
  size = 48,
  dim,
}: {
  cwd: string;
  title: string;
  online?: boolean;
  size?: number;
  dim?: boolean;
}) {
  const initials = projectInitials(cwd, title);
  const dot = Math.max(10, Math.round(size * 0.27));
  return (
    <span className="relative inline-flex shrink-0" style={{ width: size, height: size }}>
      <span
        className={`avatar inline-flex h-full w-full items-center justify-center rounded-full font-semibold tracking-wide ${dim ? "opacity-60" : ""}`}
        style={{ ["--hue" as string]: projectHue(cwd || title), fontSize: Math.round(size * 0.36) }}
        aria-hidden="true"
      >
        {initials}
      </span>
      {online ? (
        <span
          className="absolute rounded-full bg-accent"
          style={{
            width: dot,
            height: dot,
            right: 0,
            bottom: 0,
            boxShadow: "0 0 0 2.5px var(--surface)",
          }}
        />
      ) : null}
    </span>
  );
}

export function CrokLogo({ size = 26, withName = true, name }: { size?: number; withName?: boolean; name?: string }) {
  return (
    <span className="inline-flex items-center gap-2">
      <span className="crok-mark" style={{ width: size, height: Math.round(size * 1.1) }} aria-hidden="true" />
      {withName ? <span className="text-[15px] font-semibold tracking-tight">{name}</span> : null}
    </span>
  );
}

export function Loading({ label }: { label?: string }) {
  const { t } = useI18n();
  return (
    <div className="flex flex-1 items-center justify-center gap-2 py-16 text-sm text-muted" role="status">
      <SpinnerIcon size={18} />
      <span>{label ?? t("loading")}</span>
    </div>
  );
}

export function Notice({
  icon,
  title,
  children,
  action,
}: {
  icon?: ReactNode;
  title: string;
  children?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="mx-auto flex max-w-md flex-col items-center px-6 py-16 text-center">
      {icon ? <div className="mb-4 text-faint">{icon}</div> : null}
      <h2 className="text-lg font-semibold">{title}</h2>
      {children ? <div className="mt-2 text-sm leading-relaxed text-muted">{children}</div> : null}
      {action ? <div className="mt-6">{action}</div> : null}
    </div>
  );
}

export function Code({ children }: { children: ReactNode }) {
  return <code className="whitespace-nowrap rounded-md bg-code px-1.5 py-0.5 font-mono text-[0.88em] text-fg">{children}</code>;
}

/** Re-renders every `intervalMs` with the current time (relative times, countdowns). */
export function useNow(intervalMs: number): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}

export type MenuItem = {
  label: string;
  icon?: ReactNode;
  tone?: "danger";
  /** Shown but not selectable (e.g. reordering while a search is active). */
  disabled?: boolean;
  onSelect: () => void;
};

/** A "⋯" button with a small popover menu. `className` positions it (default: in the flow, `relative`). */
export function ActionMenu({ label, items, className = "relative" }: { label: string; items: MenuItem[]; className?: string }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const menuId = useId();

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    // An open menu stays visible even where the trigger only shows on hover (the pointer may leave the row).
    <div ref={ref} className={className} style={open ? { opacity: 1 } : undefined}>
      <IconButton
        label={label}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        onClick={(e) => {
          e.preventDefault();
          e.stopPropagation();
          setOpen((v) => !v);
        }}
        className="h-8 w-8"
      >
        <MoreIcon size={18} />
      </IconButton>
      {open ? (
        <div
          id={menuId}
          role="menu"
          className="absolute right-0 top-9 z-30 min-w-44 overflow-hidden rounded-xl border border-line bg-surface py-1 shadow-card"
        >
          {items.map((item) => (
            <button
              key={item.label}
              role="menuitem"
              type="button"
              disabled={item.disabled}
              onClick={(e) => {
                e.preventDefault();
                e.stopPropagation();
                setOpen(false);
                item.onSelect();
              }}
              className={`flex w-full items-center gap-3 whitespace-nowrap px-3.5 py-2 text-left text-sm hover:bg-hover disabled:cursor-default disabled:opacity-45 disabled:hover:bg-transparent ${
                item.tone === "danger" ? "text-danger" : "text-fg"
              }`}
            >
              <span className="text-muted">{item.icon}</span>
              {item.label}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/** A confirmation dialog on the native <dialog> (focus trap and Escape for free). */
export function ConfirmDialog({
  open,
  title,
  body,
  confirmLabel,
  cancelLabel,
  busy,
  onConfirm,
  onCancel,
}: {
  open: boolean;
  title: string;
  body: ReactNode;
  confirmLabel: string;
  cancelLabel: string;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);
  return (
    <dialog
      ref={ref}
      onCancel={(e) => {
        e.preventDefault();
        onCancel();
      }}
      className="m-auto w-[min(92vw,26rem)] rounded-2xl border border-line bg-surface p-0 text-fg shadow-card backdrop:bg-black/40"
    >
      <div className="p-6">
        <h2 className="text-base font-semibold">{title}</h2>
        <div className="mt-2 text-sm leading-relaxed text-muted">{body}</div>
        <div className="mt-6 flex justify-end gap-2">
          <Button tone="ghost" onClick={onCancel}>
            {cancelLabel}
          </Button>
          <Button tone="danger" busy={busy} onClick={onConfirm} autoFocus>
            {confirmLabel}
          </Button>
        </div>
      </div>
    </dialog>
  );
}
