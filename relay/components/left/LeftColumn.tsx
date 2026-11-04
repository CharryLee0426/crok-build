"use client";

/**
 * The left column (mobile/DESIGN.md "Web"): a stack of pages like Telegram Web's — the selected computer's Sessions,
 * a project's topics, Archived Sessions, Profile and its pages — each sliding in over the one before with a back
 * arrow. The pages below stay mounted (hidden), so going back keeps their search and scroll position.
 */
import { useClerk, useUser } from "@clerk/nextjs";
import { useMutation, useQuery } from "convex/react";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { api } from "@/convex/_generated/api";
import { computerList, groupUnread, resolveComputer } from "@/lib/computers";
import { newSessionHref } from "@/lib/new-session";
import { useConnection } from "../chrome";
import { useI18n } from "../I18nProvider";
import { useErrorText, useOrderActions, useSessionActions } from "../SessionList";
import { useSettings } from "../Settings";
import { useToast } from "../Toast";
import { useNow } from "../ui";
import { AppearancePage, DevicesPage, LanguagePage, ProfilePage } from "./ProfilePages";
import { ArchivedPage, ProjectPage, SessionsRootPage } from "./SessionsPages";
import type { LeftActions, LeftData, LeftPage } from "./types";

export type LeftInitial = {
  stack?: LeftPage[];
  editing?: boolean;
  query?: string;
  switcherOpen?: boolean;
  pickerOpen?: boolean;
  reorder?: boolean;
};

function pageKey(page: LeftPage): string {
  return page.kind === "project" ? `project:${page.key}` : page.kind;
}

/** Pure: the live frame and the dev preview hand in the data and what the buttons do. */
export function LeftColumnView({
  data,
  actions,
  activeId,
  initial,
}: {
  data: LeftData;
  actions: LeftActions;
  activeId?: string;
  initial?: LeftInitial;
}) {
  const settings = useSettings();
  const computers = useMemo(() => computerList(data.devices, data.groups), [data.devices, data.groups]);
  const selectedId = resolveComputer(settings.selectedComputer, computers);
  const selected = computers.find((c) => c.id === selectedId) ?? null;
  const [stack, setStack] = useState<LeftPage[]>(initial?.stack ?? [{ kind: "sessions" }]);
  const [editing, setEditing] = useState(initial?.editing ?? false);
  const [queries, setQueries] = useState<Record<string, string>>(() => {
    const start: Record<string, string> = {};
    if (initial?.query) start.sessions = initial.query;
    return start;
  });
  const top = stack[stack.length - 1];

  const groups = useMemo(
    () => (data.groups ? data.groups.filter((g) => g.deviceId === selectedId) : undefined),
    [data.groups, selectedId],
  );
  const archivedRows = useMemo(
    () => (data.archived ?? []).filter((row) => row.deviceId === selectedId),
    [data.archived, selectedId],
  );
  const otherUnread = useMemo(
    () => (data.groups ?? []).filter((g) => g.deviceId !== selectedId).reduce((sum, g) => sum + groupUnread(g), 0),
    [data.groups, selectedId],
  );

  const push = useCallback((page: LeftPage) => setStack((s) => [...s, page]), []);
  const pop = useCallback(() => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s)), []);
  const setQuery = (key: string, value: string) => setQueries((q) => ({ ...q, [key]: value }));

  /** The switcher: select it and go back to its root. */
  const switchTo = (id: string) => {
    settings.setSelectedComputer(id);
    setStack([{ kind: "sessions" }]);
    setEditing(false);
    setQueries({});
  };
  /** Profile's list: select it; the pages under Profile start again at the root. */
  const selectFromProfile = (id: string) => {
    settings.setSelectedComputer(id);
    setStack((s) => [{ kind: "sessions" }, ...s.filter((p) => p.kind === "profile" || p.kind === "devices" || p.kind === "appearance" || p.kind === "language")]);
    setEditing(false);
    setQueries({});
  };

  // An open session the current page doesn't show (a link, a new session, another computer's): its project's page,
  // on its computer. Profile, Archived and search results stay as they are.
  const followed = useRef<string | null>(null);
  useEffect(() => {
    if (!activeId || !data.groups || followed.current === activeId) return;
    const group = data.groups.find((g) => g.sessions.some((s) => s._id === activeId));
    if (!group) return;
    followed.current = activeId;
    const current = stack[stack.length - 1];
    if (current.kind === "project" && current.key === group.key) return;
    if (current.kind === "sessions" && (queries.sessions ?? "").trim()) return;
    if (current.kind !== "sessions" && current.kind !== "project") return;
    if (group.deviceId !== selectedId) settings.setSelectedComputer(group.deviceId);
    setEditing(false);
    setStack([{ kind: "sessions" }, { kind: "project", key: group.key }]);
    // Follows the open session only; the stack and queries are read as they are now.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeId, data.groups]);

  const render = (page: LeftPage, index: number): ReactNode => {
    switch (page.kind) {
      case "sessions":
        return (
          <SessionsRootPage
            data={data}
            actions={actions}
            computers={computers}
            selected={selected}
            onSelectComputer={switchTo}
            groups={groups}
            archivedRows={archivedRows}
            query={queries.sessions ?? ""}
            onQuery={(q) => setQuery("sessions", q)}
            editing={editing}
            onEditing={setEditing}
            activeId={activeId}
            onOpenProject={(key) => push({ kind: "project", key })}
            onOpenArchived={() => push({ kind: "archived" })}
            onOpenProfile={() => push({ kind: "profile" })}
            otherUnread={otherUnread}
            initialSwitcherOpen={index === stack.length - 1 && initial?.switcherOpen}
            initialPickerOpen={initial?.pickerOpen}
          />
        );
      case "project":
        return (
          <ProjectPage
            group={data.groups?.find((g) => g.key === page.key)}
            data={data}
            actions={actions}
            activeId={activeId}
            onBack={pop}
            query={queries[pageKey(page)] ?? ""}
            onQuery={(q) => setQuery(pageKey(page), q)}
            initialReorder={initial?.reorder}
          />
        );
      case "archived":
        return (
          <ArchivedPage
            rows={data.archived === undefined ? undefined : archivedRows}
            computerName={selected?.name ?? ""}
            data={data}
            actions={actions}
            activeId={activeId}
            onBack={pop}
            query={queries.archived ?? ""}
            onQuery={(q) => setQuery("archived", q)}
          />
        );
      case "profile":
        return (
          <ProfilePage
            data={data}
            actions={actions}
            computers={computers}
            selectedId={selectedId}
            onSelectComputer={selectFromProfile}
            onBack={pop}
            onOpen={(kind) => push({ kind })}
          />
        );
      case "devices":
        return <DevicesPage data={data} actions={actions} onBack={pop} />;
      case "appearance":
        return <AppearancePage onBack={pop} />;
      case "language":
        return <LanguagePage onBack={pop} />;
    }
  };

  return (
    <div className="relative flex min-h-0 flex-1 flex-col overflow-hidden">
      {stack.map((page, index) => (
        <div
          key={`${index}:${pageKey(page)}`}
          // `invisible`, not `hidden`: showing a display:none page again would replay its slide-in.
          className={`absolute inset-0 flex flex-col bg-surface ${page === top ? "" : "invisible"} ${index > 0 ? "animate-page-in" : ""}`}
          aria-hidden={page === top ? undefined : true}
        >
          {render(page, index)}
        </div>
      ))}
    </div>
  );
}

/** The browser tab's title shows the unread total: "(3) Crok Remote". */
function useUnreadTitle(total: number) {
  useEffect(() => {
    const apply = () => {
      const base = document.title.replace(/^\(\d+\+?\)\s+/, "");
      const next = total > 0 ? `(${total > 999 ? "999+" : total}) ${base}` : base;
      if (document.title !== next) document.title = next;
    };
    apply();
    // Next.js rewrites the title on navigation: put the count back.
    const observer = new MutationObserver(apply);
    observer.observe(document.head, { childList: true, subtree: true, characterData: true });
    return () => {
      observer.disconnect();
      document.title = document.title.replace(/^\(\d+\+?\)\s+/, "");
    };
  }, [total]);
}

/** How long Refresh waits for the computers to list their sessions (a crok that predates Refresh lists them later). */
const REFRESH_WAIT_MS = 15_000;
/** Long enough to see that something happened. */
const REFRESH_MIN_MS = 600;

type RefreshRun = { id: number; startedAt: number; since: number | null; settled: boolean };

/**
 * Refresh: every online computer lists all its sessions again (`sessions:refresh`); the button spins until each has
 * (`sessions:refreshState`), or for REFRESH_WAIT_MS at most. The list itself updates as usual, live.
 */
function useRefresh(): { refreshing: boolean; refresh: () => void } {
  const { t } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const ask = useMutation(api.sessions.refresh);
  const [run, setRun] = useState<RefreshRun | null>(null);
  const lastId = useRef(0);
  const state = useQuery(api.sessions.refreshState, run?.since != null ? { since: run.since } : "skip");
  const done = run !== null && (run.settled || (run.since !== null && state !== undefined && state.pending.length === 0));

  useEffect(() => {
    if (!run) return;
    const end = run.startedAt + (done ? REFRESH_MIN_MS : REFRESH_WAIT_MS);
    const id = window.setTimeout(() => setRun(null), Math.max(0, end - Date.now()));
    return () => window.clearTimeout(id);
  }, [run, done]);

  const busy = run !== null;
  const refresh = useCallback(() => {
    if (busy) return;
    const id = ++lastId.current;
    const startedAt = Date.now();
    setRun({ id, startedAt, since: null, settled: false });
    // An answer after this run timed out (or a newer one began) changes nothing.
    const current = (update: (run: RefreshRun) => RefreshRun | null) => setRun((r) => (r?.id === id ? update(r) : r));
    ask({}).then(
      ({ asked, at }) => {
        if (asked === 0) toast.show(t("refresh_none_online"));
        current((r) => ({ ...r, since: asked > 0 ? at : null, settled: asked === 0 }));
      },
      (error: unknown) => {
        toast.show(errorText(error), "error");
        current(() => null);
      },
    );
    // errorText and toast are stable enough; the mutation is memoized by Convex.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [busy, ask, t]);

  return { refreshing: busy, refresh };
}

/** The live left column for the signed-in person. */
export function LiveLeftColumn({ activeId, version }: { activeId?: string; version: string }) {
  const router = useRouter();
  const clerk = useClerk();
  const { user } = useUser();
  const now = useNow(30_000);
  const groups = useQuery(api.sessions.groups, {});
  const archived = useQuery(api.sessions.list, { archived: true });
  const devices = useQuery(api.devices.list);
  const me = useQuery(api.users.me);
  const connection = useConnection(groups !== undefined);
  const sessions = useSessionActions();
  const order = useOrderActions();
  const rename = useMutation(api.devices.rename);
  const revoke = useMutation(api.devices.revoke);
  const revokeOthers = useMutation(api.devices.revokeOthers);
  const { refreshing, refresh } = useRefresh();

  const total = useMemo(() => (groups ?? []).reduce((sum, g) => sum + groupUnread(g), 0), [groups]);
  useUnreadTitle(total);

  const account = me
    ? { name: me.name, email: me.email, imageUrl: me.imageUrl }
    : user
      ? { name: user.fullName ?? null, email: user.primaryEmailAddress?.emailAddress ?? null, imageUrl: user.imageUrl ?? null }
      : me;

  const actions: LeftActions = {
    sessions,
    order,
    newSession: ({ deviceId, path }) => router.push(newSessionHref(deviceId, path)),
    devices: {
      rename: async (deviceId, name) => {
        await rename({ deviceId, name });
      },
      revoke: async (deviceId) => {
        await revoke({ deviceId });
      },
      revokeOthers: async () => (await revokeOthers({})).count,
    },
    refresh,
    signOut: () => void clerk.signOut({ redirectUrl: "/" }),
  };

  return (
    <LeftColumnView
      data={{ groups, archived, devices, account, connection, now, version, refreshing }}
      actions={actions}
      activeId={activeId}
    />
  );
}
