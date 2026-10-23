"use client";

import { useMutation, useQuery } from "convex/react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { api } from "@/convex/_generated/api";
import { newClientId } from "@/lib/browser";
import { relayError } from "@/lib/errors";
import { folderName, tildePath } from "@/lib/format";
import { handOverPrompt, takeQueuedPrompt } from "@/lib/new-session";
import type { EffortChoice, ModelChoice, OutboxItem, PendingPrompt } from "@/lib/types";
import { useI18n } from "../I18nProvider";
import { CheckIcon, ChevronDownIcon, ChevronLeftIcon, ComputerIcon, FolderIcon } from "../icons";
import { useErrorText } from "../SessionList";
import { ButtonLink, Loading, Notice, ProjectAvatar, useNow } from "../ui";
import { levelName } from "./BotCommands";
import { Composer } from "./SessionView";
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

/** One choice of the model and thinking-level panels. */
function SetupChoice({
  label,
  detail,
  selected,
  centered = false,
  onClick,
}: {
  label: string;
  detail?: string;
  selected: boolean;
  centered?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={selected}
      className={`flex min-h-10 items-center gap-2 rounded-xl px-3.5 py-2 transition-colors ${
        centered ? "justify-center text-center" : "text-left"
      } ${selected ? "bg-accent-soft text-accent-text" : "text-fg hover:bg-hover"}`}
    >
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[14px] font-medium">{label}</span>
        {detail ? <span className="block truncate text-[12px] text-muted">{detail}</span> : null}
      </span>
      {selected ? <CheckIcon size={16} className="shrink-0" aria-hidden /> : null}
    </button>
  );
}

/**
 * The model and thinking level for a session started on another computer, from that computer's own list
 * (`devices:models`). Unset means its default; the choice rides on `sessions:create` and its crok applies it before
 * the first prompt.
 */
function NewSessionSetup({
  models,
  model,
  effort,
  onModel,
  onEffort,
}: {
  models: readonly ModelChoice[];
  model: ModelChoice | null;
  effort: EffortChoice | null;
  onModel: (model: ModelChoice | null) => void;
  onEffort: (effort: EffortChoice | null) => void;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState<"model" | "effort" | null>(null);
  const efforts = model?.efforts ?? [];
  if (models.length === 0) return null;

  const chooseModel = (choice: ModelChoice | null) => {
    onModel(choice);
    onEffort(null);
    setOpen(null);
  };
  const pill = (panel: "model" | "effort", title: string, value: string) => (
    <button
      type="button"
      onClick={() => setOpen(open === panel ? null : panel)}
      aria-expanded={open === panel}
      className="flex h-8 max-w-[16rem] items-center gap-1 rounded-full border border-line px-3 text-[12.5px] text-muted transition-colors hover:border-accent hover:text-accent-text"
    >
      <span className="shrink-0">{title}</span>
      <span className="truncate font-medium text-fg">{value}</span>
      <ChevronDownIcon size={14} className="shrink-0" />
    </button>
  );

  return (
    <div className="mb-2 flex flex-col gap-1.5">
      {open === "model" ? (
        <div className="scroll-quiet max-h-[min(45vh,22rem)] overflow-y-auto rounded-2xl border border-line bg-surface p-1.5 shadow-card">
          <p className="px-3 py-1.5 text-[13px] font-semibold text-fg">{t("card_model_title")}</p>
          <div className="grid grid-cols-1 gap-1">
            <SetupChoice label={t("effort_default")} selected={!model} onClick={() => chooseModel(null)} />
            {models.map((choice) => (
              <SetupChoice
                key={choice.id}
                label={choice.name}
                detail={choice.description}
                selected={model?.id === choice.id}
                onClick={() => chooseModel(choice)}
              />
            ))}
          </div>
        </div>
      ) : null}
      {open === "effort" && model ? (
        <div className="scroll-quiet max-h-[min(45vh,22rem)] overflow-y-auto rounded-2xl border border-line bg-surface p-1.5 shadow-card">
          <p className="px-3 py-1.5 text-[13px] font-semibold text-fg">{t("card_effort_title")}</p>
          <div className="grid grid-cols-2 gap-1">
            <SetupChoice
              centered
              label={t("effort_default")}
              selected={!effort}
              onClick={() => {
                onEffort(null);
                setOpen(null);
              }}
            />
            {efforts.map((choice) => (
              <SetupChoice
                centered
                key={choice.id}
                label={levelName(t, choice)}
                selected={effort?.id === choice.id}
                onClick={() => {
                  onEffort(choice);
                  setOpen(null);
                }}
              />
            ))}
          </div>
        </div>
      ) : null}
      <div className="flex flex-wrap items-center gap-1.5">
        {pill("model", t("info_model"), model?.name ?? t("effort_default"))}
        {efforts.length > 0 ? pill("effort", t("info_effort"), effort ? levelName(t, effort) : t("effort_default")) : null}
      </div>
    </div>
  );
}

/**
 * The new-session screen, shaped like a session (DESIGN.md §5): header "New session" with project and computer, an
 * empty transcript saying where it will run, the composer. The first prompt shows at once while the relay adds the
 * session; then the screen becomes that session. Pure: the live screen and the dev preview hand in the data.
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
}) {
  const { t } = useI18n();
  const name = folderName(path);
  return (
    <section className="flex min-h-0 min-w-0 flex-1 flex-col bg-canvas">
      <header className="flex h-14 shrink-0 items-center gap-2 border-b border-line bg-surface px-2 sm:px-3">
        <Link
          href="/"
          aria-label={t("back")}
          title={t("back")}
          className="flex h-9 w-9 items-center justify-center rounded-full text-muted hover:bg-hover hover:text-fg lg:hidden"
        >
          <ChevronLeftIcon size={22} />
        </Link>
        <div className="flex min-w-0 flex-1 items-center gap-3 px-1.5 py-1">
          <ProjectAvatar cwd={path} title={name} dim={!online} size={38} />
          <span className="min-w-0 flex-1">
            <span className="block truncate text-[15px] font-semibold leading-tight">{t("new_session")}</span>
            <span className="block truncate text-[13px] leading-tight text-faint" title={tildePath(path)}>
              {name} · {computer}
              {online ? null : <span> · {t("offline")}</span>}
            </span>
          </span>
        </div>
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
          models && models.length > 0 ? (
            <NewSessionSetup
              models={models}
              model={model}
              effort={effort}
              onModel={onPickModel}
              onEffort={onPickEffort}
            />
          ) : null
        }
        onSend={onSend}
      />
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
  /** That computer's own models, for the picker above the composer; null while it is offline. */
  const models = useQuery(api.devices.models, { deviceId });
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
