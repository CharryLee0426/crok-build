"use client";

import { UserButton } from "@clerk/nextjs";
import { useConvexConnectionState } from "convex/react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { LANG_NAMES, LANGS } from "@/lib/i18n";
import type { LangChoice } from "@/lib/i18n";
import { useI18n } from "./I18nProvider";
import { ChatsIcon, DevicesIcon, GlobeIcon, LinkIcon, SpinnerIcon } from "./icons";
import { CrokLogo } from "./ui";

/** The signed-in header: logo, Sessions / Devices / Link a device, connection state, account menu. */
export function AppHeader({
  account,
  status,
  className = "",
}: {
  account?: ReactNode;
  status?: ReactNode;
  className?: string;
}) {
  const { t } = useI18n();
  const pathname = usePathname() ?? "/";
  const items = [
    { href: "/", label: t("nav_sessions"), icon: <ChatsIcon size={18} />, active: pathname === "/" || pathname === "/new" || pathname.startsWith("/sessions") },
    { href: "/devices", label: t("nav_devices"), icon: <DevicesIcon size={18} />, active: pathname.startsWith("/devices") },
    { href: "/link", label: t("nav_link"), icon: <LinkIcon size={18} />, active: pathname.startsWith("/link") },
  ];
  return (
    <header className={`flex h-14 shrink-0 items-center gap-2 border-b border-line bg-surface px-3 sm:px-4 ${className}`}>
      <Link href="/" className="mr-1 flex items-center rounded-lg px-1 py-1" aria-label={t("app_name")}>
        <CrokLogo size={24} withName={false} />
        <span className="ml-2 hidden text-[15px] font-semibold tracking-tight md:inline">{t("app_name")}</span>
      </Link>
      <nav className="flex items-center gap-0.5" aria-label={t("app_name")}>
        {items.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            aria-current={item.active ? "page" : undefined}
            title={item.label}
            className={`flex h-9 items-center gap-2 rounded-full px-3 text-sm transition-colors ${
              item.active ? "bg-accent-soft font-medium text-accent-text" : "text-muted hover:bg-hover hover:text-fg"
            }`}
          >
            {item.icon}
            <span className="hidden sm:inline">{item.label}</span>
          </Link>
        ))}
      </nav>
      <div className="ml-auto flex items-center gap-2">
        {status}
        <div className="flex h-9 w-9 items-center justify-center">{account ?? <UserButton />}</div>
      </div>
    </header>
  );
}

/**
 * Telegram's "Connecting…" / "Waiting for network…": shown only while the relay socket is down, after 300 ms so a
 * blip doesn't flash.
 */
export function ConnectionIndicator() {
  const { t } = useI18n();
  const state = useConvexConnectionState();
  const down = !state.isWebSocketConnected;
  const [visible, setVisible] = useState(false);
  const [offline, setOffline] = useState(false);

  useEffect(() => {
    if (!down) {
      setVisible(false);
      return;
    }
    const id = window.setTimeout(() => setVisible(true), 300);
    return () => window.clearTimeout(id);
  }, [down]);

  useEffect(() => {
    const update = () => setOffline(!navigator.onLine);
    update();
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
    };
  }, []);

  if (!visible) return null;
  return <ConnectionPill label={offline ? t("conn_offline") : t("conn_connecting")} />;
}

export function ConnectionPill({ label }: { label: string }) {
  return (
    <span
      role="status"
      className="flex items-center gap-1.5 rounded-full bg-surface-2 px-2.5 py-1 text-xs text-muted"
    >
      <SpinnerIcon size={12} />
      <span className="hidden sm:inline">{label}</span>
    </span>
  );
}

export function LanguageSelect({ className = "" }: { className?: string }) {
  const { t, choice, setChoice } = useI18n();
  return (
    <label className={`inline-flex items-center gap-1.5 text-xs text-muted ${className}`}>
      <GlobeIcon size={14} />
      <span className="sr-only">{t("footer_language")}</span>
      <select
        value={choice}
        onChange={(e) => setChoice(e.target.value as LangChoice)}
        className="cursor-pointer rounded-md bg-transparent py-1 pr-1 text-xs text-muted hover:text-fg focus:text-fg"
        aria-label={t("footer_language")}
      >
        <option value="auto">{t("lang_auto")}</option>
        {LANGS.map((lang) => (
          <option key={lang} value={lang}>
            {LANG_NAMES[lang]}
          </option>
        ))}
      </select>
    </label>
  );
}

export function Footer({ className = "" }: { className?: string }) {
  const { t } = useI18n();
  return (
    <footer
      className={`flex flex-wrap items-center justify-between gap-x-6 gap-y-2 px-4 py-6 text-xs text-faint sm:px-6 ${className}`}
    >
      <span>{t("footer_note")}</span>
      <LanguageSelect />
    </footer>
  );
}
