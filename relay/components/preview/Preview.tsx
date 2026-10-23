"use client";

/**
 * Dev-only gallery (`next dev` → /preview): every signed-in screen rendered from fixtures, without Clerk or Convex,
 * for screenshots in light and dark (`?theme=dark`) and any language (`?lang=ja`). Not part of production builds.
 */
import Link from "next/link";
import { useRouter } from "next/navigation";
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
import { useBotCards } from "@/components/session/BotCommands";
import type { BotCard } from "@/components/session/BotCommands";
import { NewSessionView } from "@/components/session/NewSession";
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
import type {
  CommandId,
  EffortChoice,
  ModelChoice,
  PendingLogin,
  PendingPrompt,
  ProjectGroup,
  PromptCommand,
  SessionDetail,
  SessionRow,
  TranscriptEvent,
} from "@/lib/types";
import {
  fakeArchived,
  fakeCards,
  fakeCatalogSession,
  fakeCommands,
  fakeComputers,
  fakeDevices,
  fakeEvents,
  fakeGroups,
  fakeLogin,
  fakePending,
  fakeSession,
  fakeStartingCommands,
  fakeStartingSession,
  FAKE_MODELS,
  FAKE_SLASH_COMMANDS,
  markdownEvents,
} from "./fixtures";

export const SCREENS = [
  "landing",
  "dashboard",
  "dashboard-empty",
  "session",
  "session-info",
  "session-offline",
  "session-waiting",
  "session-permission",
  "session-catalog",
  "session-catalog-offline",
  "session-commands",
  "session-commands-filter",
  "session-cards",
  "session-starting",
  "session-markdown",
  "session-markdown-streaming",
  "new-session",
  "new-session-sent",
  "new-session-failed",
  "new-session-offline",
  "new-session-picker",
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
function Pane({ empty = false, activeId, pickerOpen }: { empty?: boolean; activeId?: string; pickerOpen?: boolean }) {
  const router = useRouter();
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
      onNewSession={({ deviceId, path }) =>
        router.push(`/preview/new-session?device=${encodeURIComponent(deviceId)}&path=${encodeURIComponent(path)}`)
      }
      initialPickerOpen={pickerOpen}
      footer={<LanguageSelect />}
    />
  );
}

/**
 * A session screen on fixtures. The composer's commands work: `/model` and `/think` cards apply after a short fake
 * delay (and the session follows), `/new` opens the new-session preview, `/info` the panel.
 */
function SessionScreenPreview({
  session: initialSession,
  infoOpen,
  info = { state: "idle", result: null },
  events,
  commands,
  pending,
  cards: initialCards,
  draft,
}: {
  session: SessionDetail;
  infoOpen?: boolean;
  info?: InfoState;
  events?: TranscriptEvent[];
  commands?: PromptCommand[];
  pending?: PendingPrompt[];
  cards?: BotCard[];
  draft?: string;
}) {
  const router = useRouter();
  const [now] = useState(() => Date.now());
  const [session, setSession] = useState(initialSession);
  const cards = useBotCards({
    session,
    apply: async () => `cmd_fake_${Date.now()}` as CommandId,
    errorText: () => "",
    initial: initialCards,
  });
  // The fake computer applies each change after a moment.
  useEffect(() => {
    const timers = cards.cards
      .filter((card) => card.state === "applying" && card.commandId)
      .map((card) =>
        window.setTimeout(() => {
          cards.settle(card.id, "done");
          const value = card.value ?? null;
          setSession((s) => {
            if (card.kind === "model") return { ...s, model: value, effort: null };
            const effort = s.models?.find((m) => m.id === s.model)?.efforts.find((e) => e.id === value);
            return { ...s, effort: effort?.value ?? value };
          });
        }, 1400),
      );
    return () => timers.forEach((id) => window.clearTimeout(id));
    // Re-armed whenever a card changes state; settled cards drop out.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cards.cards]);

  const model: SessionModel = {
    session,
    events: events ?? fakeEvents(now),
    pagination: { canLoadMore: false, loadingMore: false, isDone: true, firstLoad: false, loadMore: noop },
    commands: commands ?? (events ? [] : fakeCommands(now)),
    pending: pending ?? (session.online && !events ? fakePending(now) : []),
    slashCommands: FAKE_SLASH_COMMANDS,
    cards: cards.cards,
    info,
    stopping: false,
    answering: null,
    now,
    actions: {
      send: noop,
      stop: noop,
      answer: noop,
      retry: noop,
      discard: noop,
      requestInfo: noop,
      setPinned: noop,
      setArchived: noop,
      newSession: () =>
        router.push(
          `/preview/new-session?device=${encodeURIComponent(session.deviceId)}&path=${encodeURIComponent(session.projectPath)}`,
        ),
      openCard: cards.open,
      chooseInCard: cards.choose,
    },
  };
  return (
    <ChatLayout header={<Header />} pane={<Pane activeId={session._id} />} inSession gate={false}>
      <SessionView model={model} initialInfoOpen={infoOpen} initialDraft={draft} />
    </ChatLayout>
  );
}

/** The new-session screen on fixtures: sending shows the prompt, then (after a moment) the starting session. */
function NewSessionPreview({
  target,
  state = "empty",
}: {
  target?: { deviceId: string; path: string };
  state?: "empty" | "sent" | "failed";
}) {
  const router = useRouter();
  const [now] = useState(() => Date.now());
  const groups = fakeGroups(now);
  const group = (target && groups.find((g) => g.deviceId === target.deviceId && g.path === target.path)) ?? groups[0];
  const text = "Add a /health endpoint that also checks the database connection, with a test.";
  const [prompt, setPrompt] = useState<PendingPrompt | null>(() =>
    state === "empty"
      ? null
      : {
          key: "c_new",
          text,
          createdAt: now,
          tick: state === "failed" ? "failed" : "sending",
          error: state === "failed" ? "No crok on MacBook Pro can start sessions right now. Start crok or Crok Desktop there." : null,
          clientId: "c_new",
        },
  );
  const [model, setModel] = useState<ModelChoice | null>(null);
  const [effort, setEffort] = useState<EffortChoice | null>(null);
  return (
    <ChatLayout header={<Header />} pane={<Pane />} inSession gate={false}>
      <NewSessionView
        deviceId={group.deviceId}
        path={group.path}
        computer={group.deviceName}
        online={group.deviceOnline}
        prompt={prompt}
        now={now}
        models={FAKE_MODELS}
        model={model}
        effort={effort}
        onPickModel={(picked) => {
          setModel(picked);
          setEffort(null);
        }}
        onPickEffort={setEffort}
        onSend={(value) => {
          setPrompt({ key: "c_new", text: value, createdAt: Date.now(), tick: "sending", clientId: "c_new" });
          window.setTimeout(() => router.replace("/preview/session-starting"), 1500);
        }}
        onRetry={(p) => setPrompt({ ...p, tick: "sending", error: null })}
        onDiscard={() => setPrompt(null)}
      />
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

function Screen({
  name,
  target,
  showcase,
}: {
  name: string;
  target?: { deviceId: string; path: string };
  showcase?: string;
}) {
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
    case "session-permission":
      return (
        <SessionScreenPreview
          session={fakeSession(now, {
            status: "waiting",
            plan: [],
            pending: {
              id: "call_7#1",
              kind: "permission",
              title: "Run npm test -- auth --runInBand",
              detail: "npm test -- auth --runInBand",
              toolKind: "execute",
              options: [
                { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
                { optionId: "allow-always", name: "Always allow npm test", kind: "allow_always" },
                { optionId: "reject-once", name: "Deny", kind: "reject_once" },
              ],
              at: now,
            },
          })}
        />
      );
    case "session-catalog":
      return <SessionScreenPreview session={fakeCatalogSession(now, true)} events={[]} />;
    case "session-catalog-offline":
      return <SessionScreenPreview session={fakeCatalogSession(now, false)} events={[]} />;
    case "session-commands":
      return <SessionScreenPreview session={fakeSession(now)} draft="/" />;
    case "session-commands-filter":
      return <SessionScreenPreview session={fakeSession(now)} draft="/re" />;
    case "session-cards":
      return (
        <SessionScreenPreview
          session={fakeSession(now, { model: "grok-4", effort: "high", status: "idle", plan: [] })}
          pending={[]}
          commands={[]}
          cards={fakeCards(now)}
        />
      );
    case "session-starting":
      return (
        <SessionScreenPreview
          session={fakeStartingSession(now)}
          events={[]}
          commands={fakeStartingCommands(now)}
          pending={fakeStartingCommands(now).map((c) => ({
            key: c.clientId ?? c._id,
            text: c.text,
            createdAt: c.createdAt,
            tick: "delivered" as const,
            commandId: c._id,
            clientId: c.clientId,
          }))}
        />
      );
    case "session-markdown":
      return <SessionScreenPreview session={fakeSession(now)} events={markdownEvents(now, showcase ?? "")} />;
    case "session-markdown-streaming":
      return (
        <SessionScreenPreview
          session={fakeSession(now, { status: "running" })}
          events={markdownEvents(now, showcase ?? "", true)}
        />
      );
    case "new-session":
      return <NewSessionPreview target={target} />;
    case "new-session-sent":
      return <NewSessionPreview target={target} state="sent" />;
    case "new-session-failed":
      return <NewSessionPreview target={target} state="failed" />;
    case "new-session-offline":
      return <NewSessionPreview target={{ deviceId: "dev_box", path: "/home/me/billing-service" }} />;
    case "new-session-picker":
      return (
        <ChatLayout header={<Header />} pane={<Pane pickerOpen />} inSession={false} gate={false}>
          <ChooseSession />
        </ChatLayout>
      );
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

/**
 * Renders after mount only: fixtures use the current time, which would differ between server and client. `target` is
 * the new-session preview's project (`?device=…&path=…`, as the list's "+" passes it).
 */
export function Preview({
  screen,
  lang,
  target,
  showcase,
}: {
  screen: string;
  lang: Lang | null;
  target?: { deviceId: string; path: string };
  /** relay/scripts/markdown-showcase.md, for the session-markdown screens. */
  showcase?: string;
}) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  if (!mounted) return null;
  const content: ReactNode = <Screen key={screen} name={screen} target={target} showcase={showcase} />;
  if (!lang) return content;
  return (
    <I18nProvider initialLang={lang} initialChoice={lang} fixed>
      {content}
    </I18nProvider>
  );
}
