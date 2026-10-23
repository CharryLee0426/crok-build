"use client";

import Link from "next/link";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { readStorage, writeStorage } from "@/lib/browser";
import {
  folderName,
  formatCost,
  formatCount,
  formatDateTime,
  formatPercent,
  formatRelative,
  tildePath,
} from "@/lib/format";
import type { MessageKey } from "@/lib/i18n";
import type {
  ModelChoice,
  PendingPrompt,
  PromptCommand,
  SessionDetail,
  SessionInfoResult,
  SlashCommand,
  TranscriptEvent,
} from "@/lib/types";
import { TopicIcon } from "../avatars";
import { useI18n } from "../I18nProvider";
import {
  ArchiveIcon,
  ArrowLeftIcon,
  CheckIcon,
  ChevronDownIcon,
  ChevronRightIcon,
  CopyIcon,
  MenuIcon,
  PinIcon,
  SendIcon,
  SpinnerIcon,
  StopIcon,
  UnarchiveIcon,
  WarningIcon,
  XIcon,
} from "../icons";
import { MenuList, Popover, useMenu } from "../menu";
import { WorkingDots } from "../SessionList";
import { useToast } from "../Toast";
import { IconButton } from "../ui";
import {
  BotCardView,
  CommandPanel,
  composerCommands,
  currentModel,
  currentValue,
  levelName,
  parseSlash,
} from "./BotCommands";
import type { BotCard, ComposerCommand, ConfigKind, LocalCommand } from "./BotCommands";
import { effortMenuItems, ModelDialog, SetupRow } from "./SetupRow";
import type { SetupRowProps } from "./SetupRow";
import { Transcript } from "./Transcript";

export type InfoState = {
  state: "idle" | "loading" | "ready" | "failed" | "offline";
  result: SessionInfoResult | null;
};

/** A model or thinking-level change on its way (`commands:setConfig` until `commands:get` says done). */
export type ConfigChange = { kind: ConfigKind; value: string };

/** Everything the session screen shows and can do; the live container and the dev preview both build one. */
export type SessionModel = {
  session: SessionDetail;
  /**
   * What the session's computer can run (`devices:models`, or `sessions:get`'s copy when that query fails): undefined
   * while loading, null when it offers no choice (offline, or an older crok).
   */
  models: readonly ModelChoice[] | null | undefined;
  /** A change the pills show with a spinner until the computer applied it. */
  config: ConfigChange | null;
  events: TranscriptEvent[];
  pagination: { canLoadMore: boolean; loadingMore: boolean; isDone: boolean; firstLoad: boolean; loadMore: () => void };
  commands: PromptCommand[] | undefined;
  pending: PendingPrompt[];
  /** The agent's slash commands (`sessions:commands`), after the device's own in the composer's list. */
  slashCommands: SlashCommand[] | undefined;
  /** This browser's `/model` and `/think` answers. */
  cards: BotCard[];
  info: InfoState;
  stopping: boolean;
  /** The pending request this viewer just answered, until the computer takes the answer. */
  answering: string | null;
  now: number;
  actions: {
    send: (text: string) => void;
    stop: () => void;
    /** Answers the session's pending permission request (`commands:answer`). */
    answer: (interactionId: string, optionId: string) => void;
    retry: (prompt: PendingPrompt) => void;
    discard: (prompt: PendingPrompt) => void;
    requestInfo: () => void;
    setPinned: (pinned: boolean) => void;
    setArchived: (archived: boolean) => void;
    /** `/new [prompt]`: a session in this one's project (with a prompt it starts at once). */
    newSession: (text?: string) => void;
    /** `/model` or `/think`, with or without an argument: a bot card. */
    openCard: (kind: ConfigKind, arg?: string) => void;
    /** A tap on a bot card's button. */
    chooseInCard: (cardId: string, value: string) => void;
    /** The setup row and Session info: `commands:setConfig`. */
    setConfig: (kind: ConfigKind, value: string) => void;
  };
};

const APP_KEYS: Record<string, MessageKey> = { tui: "app_tui", desktop: "app_desktop", cli: "app_cli" };

/** What the setup row and Session info offer for this session (mobile/DESIGN.md "Model and thinking level"). */
function useSessionSetup(model: SessionModel) {
  const { t } = useI18n();
  const { session, models, config } = model;
  const listed = models ?? null;
  const current = currentModel(listed, session.model);
  const pendingModel = config?.kind === "model" ? (listed?.find((m) => m.id === config.value) ?? null) : null;
  const shown = config?.kind === "model" ? pendingModel : current;
  const modelText = config?.kind === "model" ? (pendingModel?.name ?? config.value) : (current?.name ?? session.model);
  const efforts = shown?.efforts ?? [];
  // While a new model is on its way: the same level if it has one, else its default.
  const effortId =
    config?.kind === "reasoning_effort"
      ? config.value
      : config?.kind === "model"
        ? (efforts.find((e) => (e.value ?? e.id) === session.effort)?.id ?? shown?.defaultEffort ?? null)
        : currentValue({ ...session, models: listed }, "reasoning_effort");
  const effort = efforts.find((e) => e.id === effortId) ?? null;
  const effortText = efforts.length
    ? effort
      ? levelName(t, effort)
      : session.effort && config?.kind !== "model"
        ? levelName(t, { id: session.effort })
        : t("setup_default")
    : null;
  /** The computer offers choices: the dialog and the menu open. */
  const offers = Array.isArray(models) && models.length > 0 && session.deviceOnline && !session.starting;
  // No model reported yet but a list to pick from: the pill still offers one.
  return { listed, current, modelText: modelText ?? (offers ? t("setup_default") : null), efforts, effortId, effortText, offers };
}

export function SessionView({
  model,
  initialInfoOpen = false,
  initialDraft,
  initialModelDialog = false,
}: {
  model: SessionModel;
  initialInfoOpen?: boolean;
  /** The dev preview's composer text (the command list opens for `/`). */
  initialDraft?: string;
  /** The dev preview: Choose a Model open from the start. */
  initialModelDialog?: boolean;
}) {
  const { session, actions } = model;
  const { t } = useI18n();
  const toast = useToast();
  const [infoOpen, setInfoOpen] = useState(initialInfoOpen);
  const [modelDialog, setModelDialog] = useState(initialModelDialog);
  const setup = useSessionSetup(model);
  const busy = model.config !== null;

  const openInfo = () => {
    setInfoOpen(true);
    actions.requestInfo();
  };

  // The bot cards and the command list read the same list as the pills.
  const cardSession = useMemo(() => ({ ...session, models: setup.listed }), [session, setup.listed]);
  const commands = useMemo(() => composerCommands(t, cardSession, model.slashCommands), [t, cardSession, model.slashCommands]);

  /** The device's own commands run here; any other text, `/compact` or `/whatever` too, goes to the computer. */
  const submit = (text: string) => {
    const slash = parseSlash(text);
    const local = slash && commands.find((c) => c.local && c.name === slash.name);
    if (!slash || !local) {
      actions.send(text);
      return;
    }
    const arg = slash.arg || undefined;
    switch (local.name as LocalCommand) {
      case "new":
        actions.newSession(arg);
        break;
      case "model":
        actions.openCard("model", arg);
        break;
      case "think":
        actions.openCard("reasoning_effort", arg);
        break;
      case "stop":
        actions.stop();
        break;
      case "info":
        openInfo();
        break;
    }
  };

  const pickModel = (id: string | null) => {
    setModelDialog(false);
    if (id && id !== setup.current?.id) actions.setConfig("model", id);
  };
  const pickEffort = (id: string | null) => {
    if (id && id !== setup.effortId) actions.setConfig("reasoning_effort", id);
  };
  const openModels = () => {
    if (busy) return;
    if (setup.offers) setModelDialog(true);
    else if (model.models === null && session.deviceOnline) toast.show(t("card_unavailable", { computer: session.deviceName }));
  };

  let setupRow: SetupRowProps | null = null;
  if (session.deviceOnline && !session.starting && setup.modelText) {
    setupRow = {
      model: setup.modelText,
      modelBusy: model.config?.kind === "model",
      modelDimmed: model.models === null,
      onModel: openModels,
      effort: setup.offers ? setup.effortText : null,
      effortBusy: model.config?.kind === "reasoning_effort",
      effortItems: busy ? [] : effortMenuItems(t, setup.efforts, setup.effortId, pickEffort, false),
    };
  }

  return (
    <div className="flex h-full min-h-0 min-w-0 flex-1">
      <section className="flex min-h-0 min-w-0 flex-1 flex-col">
        <SessionHeader
          session={session}
          now={model.now}
          onInfo={() => (infoOpen ? setInfoOpen(false) : openInfo())}
          infoOpen={infoOpen}
        />
        <PlanBar plan={session.plan} />
        <Transcript
          events={model.events}
          pending={model.pending}
          commands={model.commands}
          canLoadMore={model.pagination.canLoadMore}
          loadingMore={model.pagination.loadingMore}
          isDone={model.pagination.isDone}
          firstLoad={model.pagination.firstLoad}
          loadMore={model.pagination.loadMore}
          onRetry={actions.retry}
          onDiscard={actions.discard}
          now={model.now}
          history={
            session.historyState === "none" || session.historyState === "requested"
              ? { computer: session.deviceName, online: session.deviceOnline }
              : null
          }
          cards={model.cards}
          renderCard={(card) => (
            <BotCardView card={card} session={cardSession} onChoose={(value) => actions.chooseInCard(card.id, value)} />
          )}
        />
        {session.pending && session.online ? (
          <PermissionCard
            pending={session.pending}
            computer={session.deviceName}
            answering={model.answering === session.pending.id}
            onAnswer={actions.answer}
          />
        ) : null}
        <Composer
          key={session._id}
          draftKey={`crok-draft:${session._id}`}
          initialText={initialDraft}
          online={session.deviceOnline}
          running={session.status === "running"}
          waiting={session.status === "waiting" && !session.pending}
          computer={session.deviceName}
          stopping={model.stopping}
          commands={commands}
          setup={setupRow ? <SetupRow {...setupRow} /> : null}
          onSend={submit}
          onStop={actions.stop}
        />
      </section>
      {infoOpen ? (
        <InfoPanel
          session={session}
          models={setup.listed}
          info={model.info}
          onClose={() => setInfoOpen(false)}
          onPin={() => actions.setPinned(!session.pinned)}
          onArchive={() => actions.setArchived(!session.archived)}
          onModel={setup.offers && !busy ? () => setModelDialog(true) : undefined}
          effortItems={
            setup.offers && !busy && setup.efforts.length
              ? effortMenuItems(t, setup.efforts, setup.effortId, pickEffort, false)
              : undefined
          }
        />
      ) : null}
      {Array.isArray(model.models) ? (
        <ModelDialog
          open={modelDialog}
          models={model.models}
          currentId={setup.current?.id ?? session.model}
          computer={session.deviceName}
          isNew={false}
          onPick={pickModel}
          onClose={() => setModelDialog(false)}
        />
      ) : null}
    </div>
  );
}

function SessionHeader({
  session,
  now,
  onInfo,
  infoOpen,
}: {
  session: SessionDetail;
  now: number;
  onInfo: () => void;
  infoOpen: boolean;
}) {
  const { t, lang } = useI18n();
  let status: ReactNode;
  // A session nobody runs is still reachable while its computer is online: a prompt opens it there.
  if (!session.deviceOnline) {
    status = <span className="text-faint">{t("status_offline", { time: formatRelative(session.lastActivityAt, lang, now) })}</span>;
  } else if (session.starting && session.status !== "error") {
    status = (
      <span className="text-accent-text">
        {t("status_starting")}
        <WorkingDots />
      </span>
    );
  } else if (!session.online) {
    status = <span className="text-accent-text">{t("status_online")}</span>;
  } else if (session.status === "running") {
    status = (
      <span className="text-accent-text">
        {t("status_working")}
        <WorkingDots />
      </span>
    );
  } else if (session.status === "waiting") {
    status = <span className="text-warning">{t("status_waiting", { computer: session.deviceName })}</span>;
  } else if (session.status === "error") {
    status = <span className="text-danger">{t("status_error")}</span>;
  } else {
    status = <span className="text-accent-text">{t("status_online")}</span>;
  }
  return (
    <header className="relative z-10 flex h-14 shrink-0 items-center gap-1 border-b border-line bg-surface px-2 sm:px-3">
      <Link
        href="/"
        aria-label={t("back")}
        title={t("back")}
        className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full text-muted hover:bg-hover hover:text-fg lg:hidden"
      >
        <ArrowLeftIcon size={22} />
      </Link>
      <button type="button" onClick={onInfo} className="flex min-w-0 flex-1 flex-col rounded-xl px-2 py-1 text-left">
        <span className="block w-full truncate text-[15.5px] font-semibold leading-tight">{session.title || folderName(session.cwd)}</span>
        <span className="block w-full truncate text-[13px] leading-tight">
          {status}
          <span className="text-faint">
            {" "}
            · {session.deviceName} · {folderName(session.cwd)}
          </span>
        </span>
      </button>
      <button
        type="button"
        onClick={onInfo}
        aria-label={t("session_info")}
        title={t("session_info")}
        aria-pressed={infoOpen}
        className={`flex h-11 w-11 shrink-0 items-center justify-center rounded-full transition-colors hover:bg-hover ${
          infoOpen ? "bg-hover" : ""
        }`}
      >
        <TopicIcon id={session._id} title={session.title} size={36} dimmed={!session.deviceOnline} />
      </button>
    </header>
  );
}

function currentStep(plan: SessionDetail["plan"]) {
  return (
    plan.find((p) => p.status === "in_progress") ?? plan.find((p) => p.status === "pending") ?? plan[plan.length - 1]
  );
}

function PlanStatusIcon({ status }: { status: string }) {
  if (status === "completed") return <CheckIcon size={14} className="text-accent-text" />;
  if (status === "in_progress") return <SpinnerIcon size={14} className="text-accent-text" />;
  return <span className="mx-[3px] inline-block h-2 w-2 rounded-full border border-line-strong" />;
}

/** Telegram's pinned-message bar, holding the session's plan: "Plan 3/7 · Write tests", tap to expand. */
export function PlanBar({ plan }: { plan: SessionDetail["plan"] }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  if (!plan.length) return null;
  const done = plan.filter((p) => p.status === "completed").length;
  const step = currentStep(plan);
  return (
    <div className="relative z-10 shrink-0 border-b border-line bg-surface">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-label={open ? t("hide_plan") : t("show_plan")}
        className="flex w-full items-center gap-3 px-4 py-2 text-left hover:bg-hover"
      >
        <span className="w-[3px] self-stretch rounded-full bg-accent" aria-hidden="true" />
        <span className="min-w-0 flex-1">
          <span className="block text-xs font-semibold text-accent-text">
            {t("plan")} {done}/{plan.length}
          </span>
          <span className="block truncate text-[13.5px] text-fg">{step?.content}</span>
        </span>
        <ChevronDownIcon size={18} className={`shrink-0 text-muted transition-transform ${open ? "rotate-180" : ""}`} />
      </button>
      {open ? (
        <ol className="scroll-quiet max-h-64 overflow-y-auto px-4 pb-3 pt-1">
          {plan.map((entry, i) => (
            <li key={i} className="flex items-start gap-2.5 py-1 text-[13.5px]">
              <span className="mt-0.5 flex w-4 shrink-0 justify-center">
                <PlanStatusIcon status={entry.status} />
              </span>
              <span className={entry.status === "completed" ? "text-muted line-through decoration-line-strong" : "text-fg"}>
                {entry.content}
              </span>
            </li>
          ))}
        </ol>
      ) : null}
    </div>
  );
}

function useCoarsePointer(): boolean {
  const [coarse, setCoarse] = useState(false);
  useEffect(() => {
    const query = window.matchMedia("(pointer: coarse)");
    const update = () => setCoarse(query.matches);
    update();
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  return coarse;
}

/**
 * A permission request the session waits on (run this command, edit that file), with its choices. Any of the person's
 * devices may answer; the first answer counts, and the card goes once the computer has it.
 */
export function PermissionCard({
  pending,
  computer,
  answering,
  onAnswer,
}: {
  pending: NonNullable<SessionDetail["pending"]>;
  computer: string;
  answering: boolean;
  onAnswer: (interactionId: string, optionId: string) => void;
}) {
  const { t } = useI18n();
  return (
    <div className="relative shrink-0 px-3 pt-2 sm:px-4" role="region" aria-label={pending.title}>
      <div className="mx-auto max-w-3xl rounded-2xl bg-warning-soft p-3 shadow-sm">
        <div className="flex items-start gap-2 text-[13px] text-warning">
          <WarningIcon size={16} className="mt-px shrink-0" />
          <span className="font-medium">{t("permission_asks", { computer })}</span>
        </div>
        <p className="mt-1.5 break-words text-[14px] font-semibold text-fg">{pending.title}</p>
        {pending.detail ? (
          <pre className="scroll-quiet mt-1.5 max-h-40 overflow-auto whitespace-pre-wrap break-all rounded-lg bg-surface px-2.5 py-2 font-mono text-[12.5px] text-fg">
            {pending.detail}
          </pre>
        ) : null}
        <div className="mt-2.5 flex flex-wrap items-center gap-2">
          {pending.options.map((option) => (
            <button
              key={option.optionId}
              type="button"
              disabled={answering}
              onClick={() => onAnswer(pending.id, option.optionId)}
              className={
                option.kind.startsWith("allow")
                  ? "rounded-full bg-accent px-3.5 py-1.5 text-[13px] font-medium text-accent-fg hover:bg-accent-hover disabled:opacity-50"
                  : "rounded-full border border-line bg-surface px-3.5 py-1.5 text-[13px] text-fg hover:bg-hover disabled:opacity-50"
              }
            >
              {option.name || option.optionId}
            </button>
          ))}
          {answering ? <SpinnerIcon size={16} className="text-muted" /> : null}
        </div>
      </div>
    </div>
  );
}

/**
 * Enter sends, Shift+Enter breaks the line (on touch screens Enter breaks the line and the button sends). With
 * `commands`, a Menu button leads the field (Telegram's bot menu: "☰ Menu" while empty, the icon alone once typing) and
 * the command list opens above it, from that button or from `/` typed first; ↑/↓ move, Enter or a click picks (a
 * command that takes arguments fills `/name `, the others are sent), Tab completes, Esc closes. Telegram Web's look:
 * the field and the round send button float over the session's background.
 */
export function Composer({
  draftKey,
  initialText,
  online,
  running,
  waiting = false,
  computer,
  stopping = false,
  commands,
  setup,
  placeholder,
  offlineText,
  autoFocus = false,
  onSend,
  onStop,
}: {
  /** localStorage key of the unsent text. */
  draftKey: string;
  /** Fixed starting text instead of the stored draft (the dev preview). */
  initialText?: string;
  online: boolean;
  running: boolean;
  waiting?: boolean;
  computer: string;
  stopping?: boolean;
  commands?: ComposerCommand[];
  /** Above the field: the setup row (model and thinking level); hidden while the command list is open. */
  setup?: ReactNode;
  placeholder?: string;
  offlineText?: string;
  /** Focus the field on open (the new-session screen, like a new chat). */
  autoFocus?: boolean;
  onSend: (text: string) => void;
  onStop?: () => void;
}) {
  const { t } = useI18n();
  const [text, setText] = useState(initialText ?? "");
  const ref = useRef<HTMLTextAreaElement>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const coarse = useCoarsePointer();
  const listId = useId();
  const [menuOpen, setMenuOpen] = useState(false);
  /** The text at which the list was dismissed (Esc, a click elsewhere): it stays shut until the text changes. */
  const [dismissedAt, setDismissedAt] = useState<string | null>(null);
  const [active, setActive] = useState(0);
  const remember = initialText === undefined;

  useEffect(() => {
    if (!remember) return;
    const draft = readStorage(draftKey) ?? "";
    setText(draft);
    // A restored `/…` draft doesn't pop the list open; typing does.
    setDismissedAt(draft.startsWith("/") ? draft : null);
  }, [draftKey, remember]);

  useEffect(() => {
    if (!remember) return;
    const id = window.setTimeout(() => writeStorage(draftKey, text ? text : null), 300);
    return () => window.clearTimeout(id);
  }, [draftKey, text, remember]);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 220)}px`;
  }, [text]);

  // `/` first and no space yet: the list filters by what follows. The Menu button shows it whatever the text.
  const typed = commands && text.startsWith("/") && !/\s/.test(text) ? text.slice(1).toLowerCase() : null;
  const shown = useMemo(
    () => (!commands ? [] : typed === null ? commands : commands.filter((c) => c.name.toLowerCase().startsWith(typed))),
    [commands, typed],
  );
  const listOpen = shown.length > 0 && (menuOpen || (typed !== null && dismissedAt !== text));
  const highlighted = Math.min(active, Math.max(0, shown.length - 1));

  useEffect(() => {
    setActive(0);
  }, [typed, menuOpen]);

  useEffect(() => {
    if (!listOpen) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current?.contains(e.target as Node)) return;
      setMenuOpen(false);
      setDismissedAt(text);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [listOpen, text]);

  if (!online) {
    return (
      <div className="relative shrink-0 px-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-2 sm:px-4">
        <p className="mx-auto max-w-3xl rounded-2xl bg-surface px-4 py-3 text-center text-[13.5px] leading-relaxed text-muted shadow-sm">
          {offlineText ?? t("composer_offline", { computer })}
        </p>
      </div>
    );
  }

  const clear = () => {
    setText("");
    if (remember) writeStorage(draftKey, null);
  };

  const submit = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    onSend(trimmed);
    clear();
    setMenuOpen(false);
    ref.current?.focus();
  };

  const pick = (command: ComposerCommand) => {
    setMenuOpen(false);
    ref.current?.focus();
    if (command.takesArgs) {
      setText(`/${command.name} `);
      return;
    }
    onSend(`/${command.name}`);
    // Typed `/st…`: the command replaces it. Picked from the menu over other text: that text stays.
    if (typed !== null) clear();
  };

  return (
    <div className="relative shrink-0 px-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-2 sm:px-4">
      <div ref={rootRef} className="relative mx-auto max-w-3xl">
        {listOpen ? (
          <CommandPanel id={listId} commands={shown} active={highlighted} onHover={setActive} onPick={pick} />
        ) : null}
        {waiting ? (
          <div className="mb-2 flex items-start gap-2 rounded-xl bg-warning-soft px-3 py-2 text-[13px] text-warning shadow-sm">
            <WarningIcon size={16} className="mt-px shrink-0" />
            <span>{t("composer_waiting", { computer })}</span>
          </div>
        ) : null}
        {listOpen ? null : setup}
        <form
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
          className="flex items-end gap-2"
        >
          <div className="flex min-h-[46px] min-w-0 flex-1 items-end rounded-[23px] bg-surface shadow-[0_1px_2px_rgb(0_0_0/0.12),0_2px_10px_rgb(0_0_0/0.06)] ring-1 ring-line transition-shadow focus-within:ring-accent/60">
            {commands ? (
              <button
                type="button"
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => {
                  if (listOpen && menuOpen) setMenuOpen(false);
                  else {
                    setMenuOpen(true);
                    setDismissedAt(null);
                  }
                  ref.current?.focus();
                }}
                aria-label={t("menu")}
                title={t("commands_label")}
                aria-haspopup="listbox"
                aria-expanded={listOpen}
                aria-controls={listOpen ? listId : undefined}
                className={`mb-[7px] ml-[7px] flex h-8 shrink-0 items-center justify-center gap-1.5 rounded-full bg-accent text-[14px] font-medium text-accent-fg transition-[background-color,width,padding] hover:bg-accent-hover ${
                  text ? "w-8 px-0" : "pl-2.5 pr-3.5"
                }`}
              >
                <MenuIcon size={17} />
                {text ? null : <span>{t("menu")}</span>}
              </button>
            ) : null}
            <textarea
              ref={ref}
              value={text}
              rows={1}
              autoFocus={autoFocus}
              onChange={(e) => {
                setText(e.target.value);
                if (dismissedAt !== null && e.target.value !== dismissedAt) setDismissedAt(null);
              }}
              onKeyDown={(e) => {
                const composing = e.nativeEvent.isComposing || e.keyCode === 229; // IME candidate confirmation
                if (listOpen && !composing) {
                  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                    e.preventDefault();
                    const step = e.key === "ArrowDown" ? 1 : -1;
                    setActive((highlighted + step + shown.length) % shown.length);
                    return;
                  }
                  if (e.key === "Tab" && !e.shiftKey) {
                    e.preventDefault();
                    setText(`/${shown[highlighted].name} `);
                    setMenuOpen(false);
                    return;
                  }
                  if (e.key === "Escape") {
                    // Closes the list only, not the info panel behind it.
                    e.preventDefault();
                    e.stopPropagation();
                    setMenuOpen(false);
                    setDismissedAt(text);
                    return;
                  }
                  if (e.key === "Enter" && !e.shiftKey && !e.altKey) {
                    e.preventDefault();
                    pick(shown[highlighted]);
                    return;
                  }
                }
                if (e.key !== "Enter" || e.shiftKey || e.altKey || coarse || composing) return;
                e.preventDefault();
                submit();
              }}
              placeholder={placeholder ?? (running ? t("composer_placeholder_running") : t("composer_placeholder"))}
              aria-label={t("composer_label")}
              title={coarse ? undefined : t("composer_hint")}
              role={commands ? "combobox" : undefined}
              aria-autocomplete={commands ? "list" : undefined}
              aria-expanded={commands ? listOpen : undefined}
              aria-controls={listOpen ? listId : undefined}
              aria-activedescendant={listOpen ? `${listId}-${highlighted}` : undefined}
              className={`scroll-quiet max-h-[220px] min-h-[46px] min-w-0 flex-1 resize-none bg-transparent py-[11px] pr-4 text-[15px] leading-6 text-fg placeholder:text-faint focus:outline-none ${
                commands ? "pl-2.5" : "pl-4"
              }`}
            />
          </div>
          {running && onStop ? (
            <button
              type="button"
              onClick={onStop}
              disabled={stopping}
              aria-label={stopping ? t("stopping") : t("stop")}
              title={stopping ? t("stopping") : t("stop")}
              className="flex h-[46px] w-[46px] shrink-0 items-center justify-center rounded-full bg-surface text-fg shadow-[0_1px_2px_rgb(0_0_0/0.12),0_2px_10px_rgb(0_0_0/0.06)] ring-1 ring-line hover:bg-surface-2 disabled:opacity-60"
            >
              {stopping ? <SpinnerIcon size={18} /> : <StopIcon size={20} />}
            </button>
          ) : null}
          {!running || text.trim() ? (
            <button
              type="submit"
              disabled={!text.trim()}
              aria-label={t("send")}
              title={t("send")}
              className="flex h-[46px] w-[46px] shrink-0 items-center justify-center rounded-full bg-accent text-accent-fg shadow-[0_1px_2px_rgb(0_0_0/0.15)] transition-opacity hover:bg-accent-hover disabled:opacity-60"
            >
              <SendIcon size={20} />
            </button>
          ) : null}
        </form>
      </div>
    </div>
  );
}

function InfoRow({
  label,
  children,
  mono,
  onClick,
  actionLabel,
}: {
  label: string;
  children: ReactNode;
  mono?: boolean;
  /** Makes the value a button (the model and thinking level open their dialog and menu). */
  onClick?: (el: HTMLButtonElement) => void;
  actionLabel?: string;
}) {
  return (
    <div className="flex items-baseline justify-between gap-4 py-2">
      <dt className="shrink-0 text-[13px] text-muted">{label}</dt>
      <dd className={`min-w-0 text-right text-[13.5px] text-fg ${mono ? "break-all font-mono text-[12.5px]" : "break-words"}`}>
        {onClick ? (
          <button
            type="button"
            onClick={(e) => onClick(e.currentTarget)}
            title={actionLabel}
            className="-mr-1 rounded-md text-right font-medium text-accent-text hover:underline"
          >
            {children}
            <ChevronRightIcon size={14} className="ml-0.5 inline-block align-[-2px]" />
          </button>
        ) : (
          children
        )}
      </dd>
    </div>
  );
}

function CopyButton({ value }: { value: string }) {
  const { t } = useI18n();
  const [copied, setCopied] = useState(false);
  return (
    <IconButton
      label={copied ? t("copied") : t("copy")}
      className="h-7 w-7"
      onClick={() => {
        navigator.clipboard?.writeText(value).then(
          () => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1500);
          },
          () => {},
        );
      }}
    >
      {copied ? <CheckIcon size={14} /> : <CopyIcon size={14} />}
    </IconButton>
  );
}

/**
 * Session info, the right column (a full-height panel over the session below 1024 px): model and thinking level (they
 * open the model dialog and the thinking menu while the computer offers choices), folder, branch, computer, tokens,
 * cost, context, plan, id. Stored values, refreshed from the computer.
 */
export function InfoPanel({
  session,
  models,
  info,
  onClose,
  onPin,
  onArchive,
  onModel,
  effortItems,
}: {
  session: SessionDetail;
  /** The computer's list (`devices:models`), for the model's and level's names. */
  models: readonly ModelChoice[] | null;
  info: InfoState;
  onClose: () => void;
  onPin: () => void;
  onArchive: () => void;
  /** Opens Choose a Model; unset while the computer offers no choice. */
  onModel?: () => void;
  /** The thinking menu's items; unset while there is nothing to pick. */
  effortItems?: ReturnType<typeof effortMenuItems>;
}) {
  const { t, lang } = useI18n();
  const effortMenu = useMenu();
  // Fresh numbers, or (a session nobody runs) the ones the relay kept.
  const r = info.result;
  const model = r?.model ?? session.model;
  const effort = r?.effort ?? session.effort;
  const cwd = r?.cwd ?? session.cwd;
  const branch = r?.gitBranch ?? session.gitBranch;
  const usage = { ...(session.usage ?? {}), ...(r?.usage ?? {}) };
  const used = r?.context?.used ?? session.usage?.contextTokens;
  const window_ = r?.context?.window ?? session.usage?.contextWindow;
  const ratio = used !== undefined && window_ ? Math.min(1, used / window_) : null;
  // The computer's own names when it shared its models (the session names them by id).
  const named = { ...session, models, model, effort };
  const current = currentModel(models, model);
  const modelLabel = current?.name ?? model;
  const effortId = currentValue(named, "reasoning_effort");
  const effortChoice = current?.efforts.find((e) => e.id === effortId);
  const effortLabel = effortChoice ? levelName(t, effortChoice) : effort ? levelName(t, { id: effort }) : null;
  const appKey = APP_KEYS[session.app];
  const createdAt = r?.createdAt ?? session.createdAt;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const note =
    info.state === "loading" ? (
      <span className="flex items-center gap-2">
        <SpinnerIcon size={13} />
        {t("info_updating")}
      </span>
    ) : info.state === "offline" ? (
      session.deviceOnline ? t("info_stored", { computer: session.deviceName }) : t("info_offline")
    ) : info.state === "failed" ? (
      t("info_failed")
    ) : null;

  return (
    <>
      <div className="fixed inset-0 z-30 bg-black/30 lg:hidden" onClick={onClose} aria-hidden="true" />
      <aside
        aria-label={t("session_info")}
        className="scroll-quiet fixed inset-y-0 right-0 z-40 flex w-full flex-col overflow-y-auto bg-surface shadow-card sm:w-[360px] sm:border-l sm:border-line lg:static lg:z-auto lg:w-[360px] lg:shrink-0 lg:shadow-none"
      >
        <div className="flex h-14 shrink-0 items-center gap-2 border-b border-line px-2">
          <IconButton label={t("close")} onClick={onClose} className="h-10 w-10">
            <XIcon size={20} />
          </IconButton>
          <h2 className="text-[16px] font-semibold">{t("session_info")}</h2>
        </div>
        <div className="flex flex-col items-center px-5 pb-4 pt-6 text-center">
          <TopicIcon id={session._id} title={session.title} size={80} dimmed={!session.deviceOnline} />
          <h3 className="mt-3 text-base font-semibold leading-snug">{session.title || folderName(session.cwd)}</h3>
          <p className="mt-0.5 text-[13px] text-muted">
            {session.deviceName} · {folderName(session.cwd)}
          </p>
          {note ? <p className="mt-3 rounded-lg bg-surface-2 px-3 py-1.5 text-xs text-muted">{note}</p> : null}
        </div>

        <dl className="mx-4 divide-y divide-line rounded-xl border border-line px-3">
          <InfoRow label={t("info_model")} onClick={onModel ? () => onModel() : undefined} actionLabel={t("change_model")}>
            {modelLabel ?? "—"}
          </InfoRow>
          {effortLabel || effortItems ? (
            <InfoRow
              label={t("info_effort")}
              onClick={effortItems ? (el) => (effortMenu.open ? effortMenu.close() : effortMenu.fromElement(el)) : undefined}
              actionLabel={t("change_effort")}
            >
              {effortLabel ?? t("setup_default")}
            </InfoRow>
          ) : null}
          <InfoRow label={t("info_folder")} mono>
            {tildePath(cwd)}
          </InfoRow>
          {branch ? (
            <InfoRow label={t("info_branch")} mono>
              {branch}
            </InfoRow>
          ) : null}
          <InfoRow label={t("info_computer")}>
            {session.deviceName}
            {session.devicePlatform ? <span className="text-muted"> · {session.devicePlatform}</span> : null}
          </InfoRow>
          <InfoRow label={t("info_app")}>{appKey ? t(appKey) : session.app}</InfoRow>
          <InfoRow label={t("info_started")}>{formatDateTime(createdAt, lang)}</InfoRow>
          {r?.messages !== undefined ? <InfoRow label={t("info_messages")}>{formatCount(r.messages, lang)}</InfoRow> : null}
        </dl>
        {effortMenu.anchor && effortItems ? (
          <Popover anchor={effortMenu.anchor} onClose={effortMenu.close} placement="bottom-end" label={t("info_effort")}>
            <MenuList items={effortItems} onDone={effortMenu.close} />
          </Popover>
        ) : null}

        <h4 className="mx-5 mb-1.5 mt-5 text-xs font-semibold uppercase tracking-wide text-faint">{t("info_tokens")}</h4>
        <dl className="mx-4 divide-y divide-line rounded-xl border border-line px-3">
          <InfoRow label={t("info_input")}>{usage.inputTokens !== undefined ? formatCount(usage.inputTokens, lang) : "—"}</InfoRow>
          <InfoRow label={t("info_output")}>{usage.outputTokens !== undefined ? formatCount(usage.outputTokens, lang) : "—"}</InfoRow>
          {usage.cachedTokens !== undefined ? (
            <InfoRow label={t("info_cached")}>{formatCount(usage.cachedTokens, lang)}</InfoRow>
          ) : null}
          {usage.reasoningTokens !== undefined ? (
            <InfoRow label={t("info_reasoning")}>{formatCount(usage.reasoningTokens, lang)}</InfoRow>
          ) : null}
          <InfoRow label={t("info_cost")}>{usage.costUsd !== undefined ? formatCost(usage.costUsd, lang) : "—"}</InfoRow>
        </dl>

        {ratio !== null && used !== undefined && window_ ? (
          <div className="mx-4 mt-4 rounded-xl border border-line px-3 py-3">
            <div className="flex items-baseline justify-between text-[13px]">
              <span className="text-muted">{t("info_context")}</span>
              <span className="tabular-nums">{formatPercent(ratio, lang)}</span>
            </div>
            <div className="mt-2 h-2 overflow-hidden rounded-full bg-surface-2">
              <div
                className={`h-full rounded-full ${ratio > 0.85 ? "bg-warning" : "bg-accent"}`}
                style={{ width: `${Math.max(2, ratio * 100)}%` }}
              />
            </div>
            <div className="mt-1.5 text-xs text-faint tabular-nums">
              {t("info_context_of", { used: formatCount(used, lang), window: formatCount(window_, lang) })}
            </div>
          </div>
        ) : null}

        {session.plan.length ? (
          <>
            <h4 className="mx-5 mb-1.5 mt-5 text-xs font-semibold uppercase tracking-wide text-faint">{t("plan")}</h4>
            <ol className="mx-4 rounded-xl border border-line px-3 py-2">
              {session.plan.map((entry, i) => (
                <li key={i} className="flex items-start gap-2.5 py-1 text-[13px]">
                  <span className="mt-0.5 flex w-4 shrink-0 justify-center">
                    <PlanStatusIcon status={entry.status} />
                  </span>
                  <span className={entry.status === "completed" ? "text-muted" : "text-fg"}>{entry.content}</span>
                </li>
              ))}
            </ol>
          </>
        ) : null}

        <h4 className="mx-5 mb-1.5 mt-5 text-xs font-semibold uppercase tracking-wide text-faint">{t("info_session_id")}</h4>
        <div className="mx-4 flex items-center gap-2 rounded-xl border border-line py-1.5 pl-3 pr-1.5">
          <code className="min-w-0 flex-1 break-all font-mono text-[12px] text-muted">{session.sessionId}</code>
          <CopyButton value={session.sessionId} />
        </div>

        <div className="mx-4 mb-6 mt-5 flex gap-2">
          <button
            type="button"
            onClick={onPin}
            className="flex flex-1 items-center justify-center gap-2 rounded-xl border border-line py-2 text-[13px] hover:bg-hover"
          >
            <PinIcon size={15} />
            {session.pinned ? t("action_unpin") : t("action_pin")}
          </button>
          <button
            type="button"
            onClick={onArchive}
            className="flex flex-1 items-center justify-center gap-2 rounded-xl border border-line py-2 text-[13px] hover:bg-hover"
          >
            {session.archived ? <UnarchiveIcon size={15} /> : <ArchiveIcon size={15} />}
            {session.archived ? t("action_unarchive") : t("action_archive")}
          </button>
        </div>
      </aside>
    </>
  );
}
