"use client";

import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { AccountGate } from "./AccountGate";
import { AppHeader, ConnectionIndicator, Footer } from "./chrome";
import { useI18n } from "./I18nProvider";
import { ChatsIcon } from "./icons";
import { SessionsPane } from "./SessionList";

/**
 * The chat layout: the session list and the open session. Narrow screens show one at a time (the list on `/`, the
 * session full-screen with its own back button on `/sessions/…`); from `lg` up they sit side by side, like
 * Telegram's desktop apps. `gate` holds the body until the relay account is ready (off in the dev preview).
 */
export function ChatLayout({
  header,
  pane,
  inSession,
  gate = true,
  children,
}: {
  header: ReactNode;
  pane: ReactNode;
  inSession: boolean;
  gate?: boolean;
  children: ReactNode;
}) {
  const body = (
    <div className="flex min-h-0 flex-1">
      <aside
        className={`${inSession ? "hidden lg:flex" : "flex"} min-h-0 w-full flex-col lg:w-[380px] lg:shrink-0 lg:border-r lg:border-line`}
      >
        {pane}
      </aside>
      <main className={`${inSession ? "flex" : "hidden lg:flex"} min-h-0 min-w-0 flex-1`}>{children}</main>
    </div>
  );
  return (
    <div className="flex h-dvh flex-col overflow-hidden">
      <div className={inSession ? "hidden lg:block" : ""}>{header}</div>
      {gate ? <AccountGate>{body}</AccountGate> : body}
    </div>
  );
}

/**
 * The live chat frame for signed-in people (`/`, `/sessions/[id]` and the new-session screen `/new`); it stays mounted
 * across those routes.
 */
export function ChatsFrame({ children }: { children: ReactNode }) {
  const pathname = usePathname() ?? "/";
  const activeId = /^\/sessions\/([^/?#]+)/.exec(pathname)?.[1];
  return (
    <ChatLayout
      header={<AppHeader status={<ConnectionIndicator />} />}
      pane={<SessionsPane activeId={activeId} />}
      inSession={Boolean(activeId) || pathname === "/new"}
    >
      {children}
    </ChatLayout>
  );
}

/** The right-hand placeholder on wide screens when no session is open. */
export function ChooseSession() {
  const { t } = useI18n();
  return (
    <div className="flex flex-1 items-center justify-center bg-canvas">
      <div className="max-w-xs px-6 text-center">
        <ChatsIcon size={36} className="mx-auto text-faint" />
        <h2 className="mt-3 text-base font-semibold">{t("choose_session_title")}</h2>
        <p className="mt-1 text-sm text-muted">{t("choose_session")}</p>
      </div>
    </div>
  );
}

/** Devices and Link pages: header, a centred column, footer. `gate` off for the dev preview. */
export function PageFrame({
  children,
  header,
  gate = true,
}: {
  children: ReactNode;
  header?: ReactNode;
  gate?: boolean;
}) {
  return (
    <div className="flex min-h-dvh flex-col">
      {header ?? <AppHeader status={<ConnectionIndicator />} />}
      <main className="flex w-full flex-1 flex-col">{gate ? <AccountGate>{children}</AccountGate> : children}</main>
      <Footer className="mx-auto w-full max-w-2xl" />
    </div>
  );
}
