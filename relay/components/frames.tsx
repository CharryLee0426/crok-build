"use client";

import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { AccountGate } from "./AccountGate";
import { AppHeader, ConnectionIndicator, Footer } from "./chrome";
import { useI18n } from "./I18nProvider";
import { LiveLeftColumn } from "./left/LeftColumn";
import { SessionBackground, useThemeStyle } from "./SessionBackground";

/**
 * The chat frame, laid out like Telegram Web (mobile/DESIGN.md "Web"): from 1024 px the left column (380 px, a stack
 * of pages) beside the middle (the session on the theme's background; its info opens as a right column). Below
 * 1024 px one column at a time: the left column fills the window and the session slides over it. `gate` holds the
 * body until the relay account is ready (off in the dev preview).
 */
export function ChatLayout({
  left,
  inSession,
  gate = true,
  children,
}: {
  left: ReactNode;
  inSession: boolean;
  gate?: boolean;
  children: ReactNode;
}) {
  const { style, wallpaper } = useThemeStyle();
  const body = (
    <div className="flex min-h-0 flex-1">
      <aside
        className={`${inSession ? "hidden lg:flex" : "flex"} min-h-0 w-full min-w-0 flex-col bg-surface lg:w-[380px] lg:shrink-0 lg:border-r lg:border-line`}
      >
        {left}
      </aside>
      <main
        style={style}
        data-wallpaper={wallpaper ? "" : undefined}
        className={`${inSession ? "flex" : "hidden lg:flex"} relative min-h-0 min-w-0 flex-1 overflow-hidden`}
      >
        <SessionBackground />
        <div
          key={inSession ? "session" : "none"}
          className={`relative flex min-h-0 min-w-0 flex-1 ${inSession ? "max-lg:animate-page-in" : ""}`}
        >
          {children}
        </div>
      </main>
    </div>
  );
  return <div className="flex h-dvh flex-col overflow-hidden">{gate ? <AccountGate>{body}</AccountGate> : body}</div>;
}

/**
 * The live chat frame for signed-in people (`/`, `/sessions/[id]` and the new-session screen `/new`); it stays mounted
 * across those routes, so the left column keeps its pages.
 */
export function ChatsFrame({ children, version }: { children: ReactNode; version: string }) {
  const pathname = usePathname() ?? "/";
  const activeId = /^\/sessions\/([^/?#]+)/.exec(pathname)?.[1];
  return (
    <ChatLayout
      left={<LiveLeftColumn activeId={activeId ? decodeURIComponent(activeId) : undefined} version={version} />}
      inSession={Boolean(activeId) || pathname === "/new"}
    >
      {children}
    </ChatLayout>
  );
}

/** The middle with nothing open: the theme's background and "Choose a session" in a service capsule. */
export function ChooseSession() {
  const { t } = useI18n();
  return (
    <div className="flex flex-1 items-center justify-center p-6">
      <span className="svc rounded-full px-3.5 py-1 text-[14px] font-medium">{t("choose_session_title")}</span>
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
