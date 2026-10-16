"use client";

import { useMutation, usePaginatedQuery, useQuery } from "convex/react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "@/convex/_generated/api";
import { newClientId } from "@/lib/browser";
import { relayError } from "@/lib/errors";
import type { CommandId, OutboxItem, PendingPrompt, SessionId, SessionInfoResult } from "@/lib/types";
import { ErrorBoundary } from "../AccountGate";
import { useI18n } from "../I18nProvider";
import { ChatsIcon } from "../icons";
import { useErrorText, useSessionActions } from "../SessionList";
import { useToast } from "../Toast";
import { ButtonLink, Loading, Notice, useNow } from "../ui";
import { SessionView } from "./SessionView";
import type { InfoState, SessionModel } from "./SessionView";

const WATCH_EVERY_MS = 60_000;
const INFO_TIMEOUT_MS = 15_000;

/** `/sessions/[id]`: one session, live. A foreign, removed or malformed id lands on "Session not found". */
export function SessionScreen({ id }: { id: string }) {
  const { t } = useI18n();
  return (
    <ErrorBoundary
      resetKey={id}
      fallback={(error) => {
        // A malformed id fails argument validation, whose message production deployments redact: anything that
        // doesn't look like a Convex id is "not found" too.
        const code = relayError(error).code ?? (/^[0-9a-z]{20,40}$/.test(id) ? null : "NOT_FOUND");
        return (
          <div className="flex flex-1 items-center justify-center bg-canvas">
            <Notice
              icon={<ChatsIcon size={32} />}
              title={code === "NOT_FOUND" ? t("session_not_found_title") : t("error_title")}
              action={
                <ButtonLink href="/" tone="primary">
                  {t("back_to_sessions")}
                </ButtonLink>
              }
            >
              {code === "NOT_FOUND" ? t("session_not_found") : t("error_generic")}
            </Notice>
          </div>
        );
      }}
    >
      <LiveSession key={id} id={id as SessionId} />
    </ErrorBoundary>
  );
}

function LiveSession({ id }: { id: SessionId }) {
  const toast = useToast();
  const errorText = useErrorText();
  const now = useNow(30_000);

  const session = useQuery(api.sessions.get, { sessionDocId: id });
  const transcript = usePaginatedQuery(api.sessions.events, { sessionDocId: id }, { initialNumItems: 50 });
  const commands = useQuery(api.commands.forSession, { sessionDocId: id });

  const sendPrompt = useMutation(api.commands.sendPrompt);
  const stopTurn = useMutation(api.commands.stop);
  const retryCommand = useMutation(api.commands.retry);
  const discardCommand = useMutation(api.commands.discard);
  const requestInfo = useMutation(api.commands.requestInfo);
  const answerRequest = useMutation(api.commands.answer);
  // Pin and archive from the info panel move the row in the list at once, like the list's own menu.
  const sessionActions = useSessionActions();
  const watch = useMutation(api.sessions.watch);
  const markRead = useMutation(api.sessions.markRead);

  const [outbox, setOutbox] = useState<OutboxItem[]>([]);
  const [stopping, setStopping] = useState(false);
  const [answering, setAnswering] = useState<string | null>(null);
  const [infoCommandId, setInfoCommandId] = useState<CommandId | null>(null);
  const [infoLocal, setInfoLocal] = useState<InfoState["state"]>("idle");
  const infoCommand = useQuery(api.commands.get, infoCommandId ? { commandId: infoCommandId } : "skip");

  // "I'm watching": the computer streams finely while this is fresh. On open, every 60 s, and on returning to the tab.
  useEffect(() => {
    const ping = () => {
      if (document.visibilityState === "visible") void watch({ sessionDocId: id }).catch(() => {});
    };
    ping();
    const timer = window.setInterval(ping, WATCH_EVERY_MS);
    document.addEventListener("visibilitychange", ping);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", ping);
    };
  }, [id, watch]);

  // Read on open and whenever new replies arrive while the tab is visible.
  const unread = session?.unread ?? 0;
  useEffect(() => {
    const read = () => {
      if (document.visibilityState === "visible") void markRead({ sessionDocId: id }).catch(() => {});
    };
    if (unread > 0) read();
    document.addEventListener("visibilitychange", read);
    return () => document.removeEventListener("visibilitychange", read);
  }, [id, unread, markRead]);

  // "Stopping…" lasts until the turn actually ends.
  const running = session?.status === "running";
  useEffect(() => {
    if (!running) setStopping(false);
  }, [running]);

  // Drop optimistic bubbles once the relay holds their command (the command row carries the ticks from there).
  useEffect(() => {
    if (!commands) return;
    const known = new Set(commands.map((c) => c.clientId));
    setOutbox((items) => (items.some((i) => known.has(i.clientId)) ? items.filter((i) => !known.has(i.clientId)) : items));
  }, [commands]);

  const events = transcript.results;
  const pending = useMemo<PendingPrompt[]>(() => {
    const inTranscript = new Set(events.filter((e) => e.commandId).map((e) => e.commandId as string));
    const oldestLoaded = events.length ? events[events.length - 1].at : 0;
    const exhausted = transcript.status === "Exhausted";
    const serverClientIds = new Set((commands ?? []).map((c) => c.clientId));
    const list: PendingPrompt[] = [];
    for (const item of outbox) {
      if (serverClientIds.has(item.clientId)) continue;
      list.push({
        key: item.clientId,
        text: item.text,
        createdAt: item.createdAt,
        tick: item.error ? "failed" : "sending",
        error: item.error,
        clientId: item.clientId,
      });
    }
    for (const command of commands ?? []) {
      if (inTranscript.has(command._id)) continue;
      if (command.status === "done") continue;
      if (command.status === "failed" && !exhausted && command.createdAt < oldestLoaded) continue;
      list.push({
        key: command.clientId ?? command._id,
        text: command.text,
        createdAt: command.createdAt,
        tick: command.status,
        error: command.error,
        commandId: command._id,
        clientId: command.clientId,
      });
    }
    return list.sort((a, b) => a.createdAt - b.createdAt);
  }, [events, commands, outbox, transcript.status]);

  const send = useCallback(
    (text: string, clientId = newClientId()) => {
      setOutbox((items) => [
        ...items.filter((i) => i.clientId !== clientId),
        { clientId, text, createdAt: Date.now() },
      ]);
      sendPrompt({ sessionDocId: id, text, clientId }).catch((error) => {
        const message = errorText(error);
        setOutbox((items) => items.map((i) => (i.clientId === clientId ? { ...i, error: message } : i)));
      });
    },
    [id, sendPrompt, errorText],
  );

  // "Answering…" lasts until the computer takes the answer (the request goes from the session).
  const pendingId = session?.pending?.id ?? null;
  useEffect(() => {
    if (answering && answering !== pendingId) setAnswering(null);
  }, [answering, pendingId]);

  // Info: ask the computer for fresh numbers when the panel opens. For a session nobody runs the relay answers at once
  // with what the computer last reported.
  const doRequestInfo = useCallback(() => {
    setInfoLocal("loading");
    requestInfo({ sessionDocId: id }).then(
      ({ commandId }) => setInfoCommandId(commandId),
      (error) => setInfoLocal(relayError(error).code === "OFFLINE" ? "offline" : "failed"),
    );
  }, [id, requestInfo]);

  useEffect(() => {
    if (infoLocal !== "loading") return;
    const timer = window.setTimeout(() => setInfoLocal("failed"), INFO_TIMEOUT_MS);
    return () => window.clearTimeout(timer);
  }, [infoLocal, infoCommandId]);

  let info: InfoState = { state: infoLocal, result: null };
  if (infoCommand?.status === "done") {
    const result = (infoCommand.result ?? null) as (SessionInfoResult & { stored?: boolean }) | null;
    info = { state: result?.stored ? "offline" : "ready", result };
  } else if (infoCommand?.status === "failed") info = { state: "failed", result: null };
  else if (infoLocal === "loading" && !infoCommand) info = { state: "loading", result: null };

  if (session === undefined) return <Loading />;

  const model: SessionModel = {
    session,
    events,
    pagination: {
      canLoadMore: transcript.status === "CanLoadMore",
      loadingMore: transcript.status === "LoadingMore",
      isDone: transcript.status === "Exhausted",
      firstLoad: transcript.status === "LoadingFirstPage",
      loadMore: () => transcript.loadMore(50),
    },
    commands,
    pending,
    info,
    stopping,
    answering,
    now,
    actions: {
      send: (text) => send(text),
      answer: (interactionId, optionId) => {
        setAnswering(interactionId);
        answerRequest({ sessionDocId: id, interactionId, optionId }).catch((error) => {
          setAnswering(null);
          toast.show(errorText(error), "error");
        });
      },
      stop: () => {
        setStopping(true);
        stopTurn({ sessionDocId: id }).catch((error) => {
          setStopping(false);
          toast.show(errorText(error), "error");
        });
      },
      retry: (prompt) => {
        if (prompt.commandId) {
          retryCommand({ commandId: prompt.commandId }).catch((error) => toast.show(errorText(error), "error"));
        } else if (prompt.clientId) {
          send(prompt.text, prompt.clientId);
        }
      },
      discard: (prompt) => {
        if (prompt.commandId) {
          discardCommand({ commandId: prompt.commandId }).catch((error) => toast.show(errorText(error), "error"));
        } else {
          setOutbox((items) => items.filter((i) => i.clientId !== prompt.clientId));
        }
      },
      requestInfo: doRequestInfo,
      setPinned: (pinned) => sessionActions.setPinned(id, pinned),
      setArchived: (archived) => sessionActions.setArchived(id, archived),
    },
  };

  return <SessionView model={model} />;
}
