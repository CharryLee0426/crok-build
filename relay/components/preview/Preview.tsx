"use client";

/**
 * Dev-only gallery (`next dev` → /preview): every signed-in screen rendered from fixtures, without Clerk or Convex,
 * for screenshots in light and dark (`?theme=dark`) and any language (`?lang=ja`). Not part of production builds.
 */
import Link from "next/link";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { AppHeader } from "@/components/chrome";
import { DevicesView } from "@/components/Devices";
import { ChatLayout, ChooseSession, PageFrame } from "@/components/frames";
import { I18nProvider } from "@/components/I18nProvider";
import { Landing } from "@/components/Landing";
import { LinkApprovalView, LinkEntry } from "@/components/LinkDevice";
import type { LinkOutcome } from "@/components/LinkDevice";
import { SessionsPaneView } from "@/components/SessionList";
import type { OrderActions, SessionActions, Tab } from "@/components/SessionList";
import { SessionView } from "@/components/session/SessionView";
import type { InfoState, SessionModel } from "@/components/session/SessionView";
import { LanguageSelect } from "@/components/chrome";
import type { Lang } from "@/lib/i18n";
import {
  addSession,
  applyProjectOrder,
  applyResetOrder,
  applySessionOrder,
  patchSession,
  removeSession,
} from "@/lib/order";
import type { PendingLogin, ProjectGroup, SessionDetail, SessionRow, TranscriptEvent } from "@/lib/types";
import {
  fakeArchived,
  fakeCatalogSession,
  fakeCommands,
  fakeComputers,
  fakeDevices,
  fakeEvents,
  fakeGroups,
  fakeLogin,
  fakePending,
  fakeSession,
} from "./fixtures";

export const SCREENS = [
  "landing",
  "dashboard",
  "dashboard-empty",
  "session",
  "session-info",
  "session-offline",
  "session-waiting",
  "session-catalog",
  "session-catalog-offline",
  "link",
  "link-request",
  "link-approved",
  "link-approved-app",
  "link-denied",
  "link-expired",
  "link-used",
  "link-not-found",
  "devices",
] as const;

const noop = () => {};

function FakeAccount() {
  return (
    <span className="flex h-8 w-8 items-center justify-center rounded-full bg-accent text-xs font-semibold text-accent-fg">
      CL
    </span>
  );
}

function Header() {
  return <AppHeader account={<FakeAccount />} />;
}

/** The list with fake data that still moves: pin, archive and reorder apply locally, with the relay's rules. */
function Pane({ empty = false, activeId }: { empty?: boolean; activeId?: string }) {
  const [tab, setTab] = useState<Tab>("all");
  const [query, setQuery] = useState("");
  const [now] = useState(() => Date.now());
  const [groups, setGroups] = useState<ProjectGroup[]>(() => (empty ? [] : fakeGroups(now)));
  const [archived, setArchived] = useState<SessionRow[]>(() => (empty ? [] : fakeArchived(now)));
  const actions: SessionActions = {
    setPinned: (id, pinned) => {
      setGroups((g) => patchSession(g, id, { pinned }));
      setArchived((rows) => rows.map((r) => (r._id === id ? { ...r, pinned } : r)));
    },
    setArchived: (id, archive) => {
      const row = [...groups.flatMap((g) => g.sessions), ...archived].find((r) => r._id === id);
      if (!row) return;
      const moved = { ...row, archived: archive, pinned: archive ? false : row.pinned };
      setGroups((g) => (archive ? removeSession(g, id) : addSession(g, moved)));
      setArchived((rows) => (archive ? [moved, ...rows] : rows.filter((r) => r._id !== id)));
    },
    stop: noop,
  };
  const order: OrderActions = {
    reorderProjects: (keys) => setGroups((g) => applyProjectOrder(g, keys)),
    reorderSessions: (key, ids) => setGroups((g) => applySessionOrder(g, key, ids)),
    resetOrder: (key) => setGroups((g) => applyResetOrder(g, key)),
  };
  return (
    <SessionsPaneView
      groups={groups}
      archived={archived}
      computers={empty ? [] : fakeComputers()}
      tab={tab}
      onTab={setTab}
      query={query}
      onQuery={setQuery}
      activeId={activeId}
      now={now}
      actions={actions}
      order={order}
      footer={<LanguageSelect />}
    />
  );
}

function sessionModel(
  session: SessionDetail,
  info: InfoState = { state: "idle", result: null },
  events?: TranscriptEvent[],
): SessionModel {
  const now = Date.now();
  return {
    session,
    events: events ?? fakeEvents(now),
    pagination: { canLoadMore: false, loadingMore: false, isDone: true, firstLoad: false, loadMore: noop },
    commands: events ? [] : fakeCommands(now),
    pending: session.online && !events ? fakePending(now) : [],
    info,
    stopping: false,
    now,
    actions: {
      send: noop,
      stop: noop,
      retry: noop,
      discard: noop,
      requestInfo: noop,
      setPinned: noop,
      setArchived: noop,
    },
  };
}

function SessionScreenPreview({
  session,
  infoOpen,
  info,
  events,
}: {
  session: SessionDetail;
  infoOpen?: boolean;
  info?: InfoState;
  events?: TranscriptEvent[];
}) {
  return (
    <ChatLayout header={<Header />} pane={<Pane activeId={session._id} />} inSession gate={false}>
      <SessionView model={sessionModel(session, info, events)} initialInfoOpen={infoOpen} />
    </ChatLayout>
  );
}

function LinkPreview({ login, outcome, app = false }: { login: PendingLogin | null; outcome?: LinkOutcome; app?: boolean }) {
  return (
    <PageFrame header={<Header />} gate={false}>
      <LinkApprovalView
        code="BCDF-GHJK"
        login={login}
        outcome={outcome ?? null}
        busy={null}
        app={app}
        now={Date.now()}
        onApprove={noop}
        onDeny={noop}
      />
    </PageFrame>
  );
}

function Screen({ name }: { name: string }) {
  const now = Date.now();
  switch (name) {
    case "landing":
      return <Landing />;
    case "dashboard":
      return (
        <ChatLayout header={<Header />} pane={<Pane />} inSession={false} gate={false}>
          <ChooseSession />
        </ChatLayout>
      );
    case "dashboard-empty":
      return (
        <ChatLayout header={<Header />} pane={<Pane empty />} inSession={false} gate={false}>
          <ChooseSession />
        </ChatLayout>
      );
    case "session":
      return <SessionScreenPreview session={fakeSession(now)} />;
    case "session-info":
      return (
        <SessionScreenPreview
          session={fakeSession(now)}
          infoOpen
          info={{
            state: "ready",
            result: { model: "grok-code-fast-1", effort: "high", messages: 34, context: { used: 91_200, window: 256_000 } },
          }}
        />
      );
    case "session-offline":
      return (
        <SessionScreenPreview
          session={fakeSession(now, { online: false, status: "idle", deviceOnline: false, lastActivityAt: now - 3 * 3_600_000 })}
        />
      );
    case "session-waiting":
      return <SessionScreenPreview session={fakeSession(now, { status: "waiting", plan: [] })} />;
    case "session-catalog":
      return <SessionScreenPreview session={fakeCatalogSession(now, true)} events={[]} />;
    case "session-catalog-offline":
      return <SessionScreenPreview session={fakeCatalogSession(now, false)} events={[]} />;
    case "link":
      return (
        <PageFrame header={<Header />} gate={false}>
          <LinkEntry />
        </PageFrame>
      );
    case "link-request":
      return <LinkPreview login={fakeLogin(now)} />;
    case "link-approved":
      return <LinkPreview login={fakeLogin(now)} outcome={{ kind: "approved", name: "MacBook Pro" }} />;
    case "link-approved-app":
      return <LinkPreview login={fakeLogin(now, { kind: "phone", name: "iPhone 17" })} outcome={{ kind: "approved", name: "iPhone 17" }} app />;
    case "link-denied":
      return <LinkPreview login={fakeLogin(now, { status: "denied" })} />;
    case "link-expired":
      return <LinkPreview login={fakeLogin(now, { status: "expired" })} />;
    case "link-used":
      return <LinkPreview login={fakeLogin(now, { status: "consumed" })} />;
    case "link-not-found":
      return <LinkPreview login={null} />;
    case "devices":
      return (
        <PageFrame header={<Header />} gate={false}>
          <DevicesView
            devices={fakeDevices(now)}
            browserLabel="Chrome · macOS"
            now={now}
            actions={{ rename: async () => {}, revoke: async () => {}, revokeOthers: async () => 4 }}
          />
        </PageFrame>
      );
    default:
      return <Index />;
  }
}

function Index() {
  return (
    <div className="mx-auto max-w-xl px-6 py-12">
      <h1 className="text-2xl font-semibold">Preview</h1>
      <p className="mt-1 text-sm text-muted">
        Dev-only screens with fake data. Add <code>?theme=dark</code> or <code>?lang=ja</code>.
      </p>
      <ul className="mt-6 grid grid-cols-2 gap-2">
        {SCREENS.map((name) => (
          <li key={name}>
            <Link className="text-accent-text underline" href={`/preview/${name}`}>
              {name}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}

/** Renders after mount only: fixtures use the current time, which would differ between server and client. */
export function Preview({ screen, lang }: { screen: string; lang: Lang | null }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  if (!mounted) return null;
  const content: ReactNode = <Screen name={screen} />;
  if (!lang) return content;
  return (
    <I18nProvider initialLang={lang} initialChoice={lang} fixed>
      {content}
    </I18nProvider>
  );
}
