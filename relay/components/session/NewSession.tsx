"use client";

import { useMutation, useQueries, useQuery } from "convex/react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "@/convex/_generated/api";
import { newClientId } from "@/lib/browser";
import { relayError } from "@/lib/errors";
import { folderName, tildePath } from "@/lib/format";
import { handOverPrompt, takeQueuedPrompt } from "@/lib/new-session";
import type { EffortChoice, ModelChoice, OutboxItem, PendingPrompt } from "@/lib/types";
import { ForumAvatar } from "../avatars";
import { useI18n } from "../I18nProvider";
import { ArrowLeftIcon, ComputerIcon, FolderIcon } from "../icons";
import { useErrorText } from "../SessionList";
import { ButtonLink, Loading, Notice, useNow } from "../ui";
import { levelName } from "./BotCommands";
import { Composer } from "./SessionView";
import { effortMenuItems, ModelDialog, SetupRow } from "./SetupRow";
import { Transcript } from "./Transcript";

const noop = () => {};

/** Telegram's empty new chat: where the session will run, in the middle of the empty transcript. */
function StartsIn({ path, computer }: { path: string; computer: string }) {
  const { t, tx } = useI18n();
  return (
    <div className="flex max-w-sm flex-col items-center gap-3 rounded-2xl bg-surface px-6 py-5 text-center shadow-sm">
      <span className="flex h-12 w-12 items-center justify-center rounded-full bg-accent-soft text-accent-text">
        <FolderIcon size={22} />
      </span>
      <p className="text-[14px] leading-relaxed text-fg">
        {tx("new_session_starts_in", {
          path: <span className="break-all font-mono text-[13px]">{tildePath(path)}</span>,
          computer: <span className="font-semibold">{computer}</span>,
        })}
      </p>
      <p className="text-[13px] leading-relaxed text-muted">{t("new_session_lead")}</p>
    </div>
  );
}

/**
 * The new-session screen, shaped like a session (DESIGN.md §5, mobile/DESIGN.md "Web"): header "New session" with the
 * project and computer, the theme's background with where it will run, the composer with the setup row (Default until
 * a model or level is picked from that computer's `devices:models`). The first prompt shows at once while the relay
 * adds the session; then the screen becomes that session. Pure: the live screen and the dev preview hand in the data.
 */
export function NewSessionView({
  deviceId,
  path,
  computer,
  online,
  prompt,
  now,
  initialDraft,
  models = null,
  model = null,
  effort = null,
  onPickModel = noop,
  onPickEffort = noop,
  onSend,
  onRetry,
  onDiscard,
  initialModelDialog = false,
}: {
  deviceId: string;
  path: string;
  computer: string;
  online: boolean;
  /** The first prompt while `sessions:create` runs, or after it failed. */
  prompt: PendingPrompt | null;
  now: number;
  initialDraft?: string;
  /** That computer's models (`devices:models`), null while it is offline or has not published them. */
  models?: readonly ModelChoice[] | null;
  /** The model and thinking level chosen for the new session; null: its computer's default. */
  model?: ModelChoice | null;
  effort?: EffortChoice | null;
  onPickModel?: (model: ModelChoice | null) => void;
  onPickEffort?: (effort: EffortChoice | null) => void;
  onSend: (text: string) => void;
  onRetry: (prompt: PendingPrompt) => void;
  onDiscard: (prompt: PendingPrompt) => void;
  /** The dev preview: Choose a Model open from the start. */
  initialModelDialog?: boolean;
}) {
  const { t } = useI18n();
  const name = folderName(path);
  const [dialog, setDialog] = useState(initialModelDialog);
  const efforts = model?.efforts ?? [];
  const offers = Boolean(models?.length);
  return (
    <section className="flex min-h-0 min-w-0 flex-1 flex-col">
      <header className="relative z-10 flex h-14 shrink-0 items-center gap-1 border-b border-line bg-surface px-2 sm:px-3">
        <Link
          href="/"
          aria-label={t("back")}
          title={t("back")}
          className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-muted hover:bg-hover hover:text-fg lg:hidden"
        >
          <ArrowLeftIcon size={22} />
        </Link>
        <div className="min-w-0 flex-1 px-2 py-1">
          <span className="block truncate text-[15.5px] font-semibold leading-tight">{t("new_session")}</span>
          <span className="block truncate text-[13px] leading-tight text-faint" title={tildePath(path)}>
            {name} · {computer}
            {online ? null : <span> · {t("offline")}</span>}
          </span>
        </div>
        <span className="flex h-11 w-11 shrink-0 items-center justify-center">
          <ForumAvatar path={path} name={name} size={36} dimmed={!online} />
        </span>
      </header>
      <Transcript
        events={[]}
        pending={prompt ? [prompt] : []}
        commands={[]}
        canLoadMore={false}
        loadingMore={false}
        isDone={false}
        firstLoad={false}
        loadMore={noop}
        onRetry={onRetry}
        onDiscard={onDiscard}
        now={now}
        emptyNotice={<StartsIn path={path} computer={computer} />}
      />
      <Composer
        key={`${deviceId}\n${path}`}
        draftKey={`crok-draft:new:${deviceId}:${path}`}
        initialText={initialDraft}
        online={online}
        running={false}
        computer={computer}
        placeholder={t("new_session_placeholder")}
        offlineText={t("new_session_offline", { computer })}
        autoFocus
        setup={
          offers ? (
            <SetupRow
              model={model?.name ?? t("setup_default")}
              onModel={() => setDialog(true)}
              effort={model && efforts.length ? (effort ? levelName(t, effort) : t("setup_default")) : null}
              effortItems={effortMenuItems(
                t,
                efforts,
                effort?.id ?? null,
                (id) => onPickEffort(efforts.find((e) => e.id === id) ?? null),
                true,
              )}
            />
          ) : null
        }
        onSend={onSend}
      />
      {models?.length ? (
        <ModelDialog
          open={dialog}
          models={models}
          currentId={model?.id ?? null}
          computer={computer}
          isNew
          onPick={(id) => {
            setDialog(false);
            // A new model: its thinking level goes back to Default.
            onPickModel(models.find((m) => m.id === id) ?? null);
            onPickEffort(null);
          }}
          onClose={() => setDialog(false)}
        />
      ) : null}
    </section>
  );
}

/** `/new?device=…&path=…`, live: `sessions:create` on send, then the session's own screen in this history entry. */
export function NewSessionScreen({ deviceId, path }: { deviceId: string; path: string }) {
  const { t } = useI18n();
  const router = useRouter();
  const errorText = useErrorText();
  const now = useNow(30_000);
  const devices = useQuery(api.devices.list);
  const create = useMutation(api.sessions.create);
  /** That computer's own models, for the setup row; null while it is offline (an error, an older relay: none). */
  // Memoized: useQueries resubscribes whenever it gets a new object.
  const modelQueries = useMemo(() => ({ models: { query: api.devices.models, args: { deviceId } } }), [deviceId]);
  const queried = useQueries(modelQueries).models as
    | ModelChoice[]
    | null
    | undefined
    | Error;
  const models = queried instanceof Error ? null : queried;
  const [modelId, setModelId] = useState<string | null>(null);
  const [effortId, setEffortId] = useState<string | null>(null);
  const chosenModel = models?.find((m) => m.id === modelId) ?? null;
  const chosenEffort = chosenModel?.efforts.find((e) => e.id === effortId) ?? null;
  const [outbox, setOutbox] = useState<OutboxItem | null>(null);
  const device = devices?.find((d) => d._id === deviceId && d.kind === "computer");
  const computer = device?.name ?? "";

  const createErrorText = useCallback(
    (error: unknown) => {
      // The relay's own words for these: they say what is missing there (no crok running, or one too old to start
      // sessions, "update crok").
      const { code, message } = relayError(error);
      if (code === "OFFLINE") {
        return message || t("new_session_err_offline", { computer: computer || t("info_computer") });
      }
      if (code === "INVALID") return message || t("new_session_err_invalid");
      if (code === "NOT_FOUND" || code === "FORBIDDEN") return t("new_session_not_found");
      return errorText(error);
    },
    [t, computer, errorText],
  );

  const send = useCallback(
    (text: string, clientId = newClientId()) => {
      const item: OutboxItem = { clientId, text, createdAt: Date.now() };
      setOutbox(item);
      create({
        deviceId,
        path,
        text,
        model: chosenModel?.id,
        effort: chosenEffort?.id,
        clientId,
      }).then(
        ({ sessionDocId }) => {
          handOverPrompt(sessionDocId, item);
          router.replace(`/sessions/${sessionDocId}`);
        },
        (error) => setOutbox((o) => (o?.clientId === clientId ? { ...o, error: createErrorText(error) } : o)),
      );
    },
    [create, deviceId, path, router, createErrorText, chosenModel, chosenEffort],
  );

  // `/new <prompt>` in a session: its prompt waits here and goes out at once.
  useEffect(() => {
    const queued = takeQueuedPrompt(deviceId, path);
    if (queued) send(queued.text, queued.clientId);
  }, [deviceId, path, send]);

  const validPath = path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path) || path.startsWith("\\\\");
  if (devices === undefined) return <Loading />;
  if (!device || !validPath) {
    return (
      <div className="flex flex-1 items-center justify-center bg-canvas">
        <Notice
          icon={<ComputerIcon size={32} />}
          title={t("new_session_not_found_title")}
          action={
            <ButtonLink href="/" tone="primary">
              {t("back_to_sessions")}
            </ButtonLink>
          }
        >
          {t("new_session_not_found")}
        </Notice>
      </div>
    );
  }

  const prompt: PendingPrompt | null = outbox
    ? {
        key: outbox.clientId,
        text: outbox.text,
        createdAt: outbox.createdAt,
        tick: outbox.error ? "failed" : "sending",
        error: outbox.error,
        clientId: outbox.clientId,
      }
    : null;

  return (
    <NewSessionView
      deviceId={deviceId}
      path={path}
      computer={computer}
      online={device.online}
      prompt={prompt}
      now={now}
      models={models ?? null}
      model={chosenModel}
      effort={chosenEffort}
      onPickModel={(picked) => {
        setModelId(picked?.id ?? null);
        setEffortId(null);
      }}
      onPickEffort={(picked) => setEffortId(picked?.id ?? null)}
      // One session per screen: a second prompt while the first is on its way would start another.
      onSend={(text) => {
        if (!outbox || outbox.error) send(text);
      }}
      onRetry={(p) => send(p.text, p.clientId ?? undefined)}
      onDiscard={() => setOutbox(null)}
    />
  );
}
