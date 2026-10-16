"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
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
import type { PendingPrompt, PromptCommand, SessionDetail, SessionInfoResult, TranscriptEvent } from "@/lib/types";
import { useI18n } from "../I18nProvider";
import {
  ArchiveIcon,
  CheckIcon,
  ChevronDownIcon,
  ChevronLeftIcon,
  CopyIcon,
  InfoIcon,
  PinIcon,
  SendIcon,
  SpinnerIcon,
  StopIcon,
  UnarchiveIcon,
  WarningIcon,
  XIcon,
} from "../icons";
import { WorkingDots } from "../SessionList";
import { IconButton, ProjectAvatar } from "../ui";
import { Transcript } from "./Transcript";

export type InfoState = {
  state: "idle" | "loading" | "ready" | "failed" | "offline";
  result: SessionInfoResult | null;
};

/** Everything the session screen shows and can do; the live container and the dev preview both build one. */
export type SessionModel = {
  session: SessionDetail;
  events: TranscriptEvent[];
  pagination: { canLoadMore: boolean; loadingMore: boolean; isDone: boolean; firstLoad: boolean; loadMore: () => void };
  commands: PromptCommand[] | undefined;
  pending: PendingPrompt[];
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
  };
};

const APP_KEYS: Record<string, MessageKey> = { tui: "app_tui", desktop: "app_desktop", cli: "app_cli" };

export function SessionView({ model, initialInfoOpen = false }: { model: SessionModel; initialInfoOpen?: boolean }) {
  const { session, actions } = model;
  const [infoOpen, setInfoOpen] = useState(initialInfoOpen);

  const openInfo = () => {
    setInfoOpen(true);
    actions.requestInfo();
  };

  return (
    <div className="flex h-full min-h-0 min-w-0 flex-1">
      <section className="flex min-h-0 min-w-0 flex-1 flex-col bg-canvas">
        <SessionHeader session={session} now={model.now} onInfo={() => (infoOpen ? setInfoOpen(false) : openInfo())} infoOpen={infoOpen} />
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
          sessionKey={session._id}
          online={session.deviceOnline}
          running={session.status === "running"}
          waiting={session.status === "waiting" && !session.pending}
          computer={session.deviceName}
          stopping={model.stopping}
          onSend={actions.send}
          onStop={actions.stop}
        />
      </section>
      {infoOpen ? (
        <InfoPanel
          session={session}
          info={model.info}
          onClose={() => setInfoOpen(false)}
          onPin={() => actions.setPinned(!session.pinned)}
          onArchive={() => actions.setArchived(!session.archived)}
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
    <header className="flex h-14 shrink-0 items-center gap-2 border-b border-line bg-surface px-2 sm:px-3">
      <Link
        href="/"
        aria-label={t("back")}
        title={t("back")}
        className="flex h-9 w-9 items-center justify-center rounded-full text-muted hover:bg-hover hover:text-fg lg:hidden"
      >
        <ChevronLeftIcon size={22} />
      </Link>
      <button type="button" onClick={onInfo} className="flex min-w-0 flex-1 items-center gap-3 rounded-xl px-1.5 py-1 text-left">
        <ProjectAvatar cwd={session.cwd} title={session.title} online={session.online} dim={!session.deviceOnline} size={38} />
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[15px] font-semibold leading-tight">{session.title || folderName(session.cwd)}</span>
          <span className="block truncate text-[13px] leading-tight">
            {status}
            <span className="text-faint">
              {" "}
              · {session.deviceName} · {folderName(session.cwd)}
            </span>
          </span>
        </span>
      </button>
      <IconButton
        label={t("session_info")}
        onClick={onInfo}
        aria-pressed={infoOpen}
        className={infoOpen ? "bg-accent-soft text-accent-text" : ""}
      >
        <InfoIcon size={20} />
      </IconButton>
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
    <div className="shrink-0 border-b border-line bg-surface">
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
    <div className="shrink-0 border-t border-line bg-surface px-3 pt-3 sm:px-4" role="region" aria-label={pending.title}>
      <div className="mx-auto max-w-3xl rounded-2xl bg-warning-soft p-3">
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

/** Enter sends, Shift+Enter breaks the line (on touch screens Enter breaks the line and the button sends). */
function Composer({
  sessionKey,
  online,
  running,
  waiting,
  computer,
  stopping,
  onSend,
  onStop,
}: {
  sessionKey: string;
  online: boolean;
  running: boolean;
  waiting: boolean;
  computer: string;
  stopping: boolean;
  onSend: (text: string) => void;
  onStop: () => void;
}) {
  const { t } = useI18n();
  const draftKey = `crok-draft:${sessionKey}`;
  const [text, setText] = useState("");
  const ref = useRef<HTMLTextAreaElement>(null);
  const coarse = useCoarsePointer();

  useEffect(() => {
    setText(readStorage(draftKey) ?? "");
  }, [draftKey]);

  useEffect(() => {
    const id = window.setTimeout(() => writeStorage(draftKey, text ? text : null), 300);
    return () => window.clearTimeout(id);
  }, [draftKey, text]);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 220)}px`;
  }, [text]);

  if (!online) {
    return (
      <div className="shrink-0 border-t border-line bg-surface px-4 py-3">
        <p className="mx-auto max-w-3xl text-center text-[13px] leading-relaxed text-muted">
          {t("composer_offline", { computer })}
        </p>
      </div>
    );
  }

  const submit = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    onSend(trimmed);
    setText("");
    writeStorage(draftKey, null);
    ref.current?.focus();
  };

  return (
    <div className="shrink-0 border-t border-line bg-surface px-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-2.5 sm:px-4">
      <div className="mx-auto max-w-3xl">
        {waiting ? (
          <div className="mb-2 flex items-start gap-2 rounded-xl bg-warning-soft px-3 py-2 text-[13px] text-warning">
            <WarningIcon size={16} className="mt-px shrink-0" />
            <span>{t("composer_waiting", { computer })}</span>
          </div>
        ) : null}
        <form
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
          className="flex items-end gap-2"
        >
          <textarea
            ref={ref}
            value={text}
            rows={1}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key !== "Enter" || e.shiftKey || e.altKey || coarse) return;
              if (e.nativeEvent.isComposing || e.keyCode === 229) return; // IME candidate confirmation
              e.preventDefault();
              submit();
            }}
            placeholder={running ? t("composer_placeholder_running") : t("composer_placeholder")}
            aria-label={t("composer_label")}
            className="scroll-quiet max-h-[220px] min-h-11 flex-1 resize-none rounded-[22px] border border-line bg-canvas px-4 py-2.5 text-[15px] leading-6 text-fg placeholder:text-faint focus:border-accent focus:outline-none"
          />
          {running ? (
            <button
              type="button"
              onClick={onStop}
              disabled={stopping}
              aria-label={stopping ? t("stopping") : t("stop")}
              title={stopping ? t("stopping") : t("stop")}
              className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-line bg-surface text-fg hover:bg-surface-2 disabled:opacity-60"
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
              className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-accent text-accent-fg transition-opacity hover:bg-accent-hover disabled:opacity-35"
            >
              <SendIcon size={20} />
            </button>
          ) : null}
        </form>
        {!coarse ? <p className="mt-1.5 hidden px-4 text-[11px] text-faint sm:block">{t("composer_hint")}</p> : null}
      </div>
    </div>
  );
}

function InfoRow({ label, children, mono }: { label: string; children: ReactNode; mono?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-4 py-2">
      <dt className="shrink-0 text-[13px] text-muted">{label}</dt>
      <dd className={`min-w-0 text-right text-[13.5px] text-fg ${mono ? "break-all font-mono text-[12.5px]" : "break-words"}`}>
        {children}
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

/** Model, effort, folder, branch, computer, tokens, cost, context, plan, id: stored values, refreshed from the computer. */
export function InfoPanel({
  session,
  info,
  onClose,
  onPin,
  onArchive,
}: {
  session: SessionDetail;
  info: InfoState;
  onClose: () => void;
  onPin: () => void;
  onArchive: () => void;
}) {
  const { t, lang } = useI18n();
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
  const effortKey = effort ? (`effort_${effort}` as MessageKey) : null;
  const effortLabel = effortKey && effortKey in EFFORT_KEYS ? t(effortKey) : effort;
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
        className="scroll-quiet fixed inset-y-0 right-0 z-40 flex w-[min(100vw,22rem)] flex-col overflow-y-auto border-l border-line bg-surface shadow-card lg:static lg:z-auto lg:w-[22rem] lg:shrink-0 lg:shadow-none"
      >
        <div className="flex h-14 shrink-0 items-center justify-between border-b border-line px-4">
          <h2 className="text-[15px] font-semibold">{t("session_info")}</h2>
          <IconButton label={t("close")} onClick={onClose}>
            <XIcon size={18} />
          </IconButton>
        </div>
        <div className="flex flex-col items-center px-5 pb-4 pt-6 text-center">
          <ProjectAvatar cwd={session.cwd} title={session.title} online={session.online} size={68} />
          <h3 className="mt-3 text-base font-semibold leading-snug">{session.title || folderName(session.cwd)}</h3>
          <p className="mt-0.5 text-[13px] text-muted">
            {session.deviceName} · {folderName(session.cwd)}
          </p>
          {note ? <p className="mt-3 rounded-lg bg-surface-2 px-3 py-1.5 text-xs text-muted">{note}</p> : null}
        </div>

        <dl className="mx-4 divide-y divide-line rounded-xl border border-line px-3">
          <InfoRow label={t("info_model")}>{model ?? "—"}</InfoRow>
          {effortLabel ? <InfoRow label={t("info_effort")}>{effortLabel}</InfoRow> : null}
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

const EFFORT_KEYS: Record<string, true> = {
  effort_none: true,
  effort_minimal: true,
  effort_low: true,
  effort_medium: true,
  effort_high: true,
  effort_xhigh: true,
  effort_max: true,
  effort_default: true,
};
