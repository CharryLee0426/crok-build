"use client";

/**
 * Slash commands in the composer, built from Telegram's bot UI (DESIGN.md §5 "Commands in the composer"): the command
 * list above the composer, and the local "bot cards" with an inline keyboard that `/model` and `/think` answer with.
 * No Convex here: the live screen and the dev preview hand in what to do.
 */
import { useEffect, useRef, useState } from "react";
import { translate } from "@/lib/i18n";
import type { MessageKey } from "@/lib/i18n";
import type { CommandId, EffortChoice, ModelChoice, SessionDetail, SlashCommand } from "@/lib/types";
import { useI18n } from "../I18nProvider";
import { CheckIcon, SpinnerIcon } from "../icons";

/** The settings `commands:setConfig` changes. */
export type ConfigKind = "model" | "reasoning_effort";

/** One row of the composer's command list. */
export type ComposerCommand = {
  name: string;
  description: string;
  hint?: string;
  /** A tap fills `/name ` for the rest instead of sending at once. */
  takesArgs: boolean;
  /** Handled on this device (`/new`, `/model`, …) rather than sent to the computer. */
  local: boolean;
};

/** The device's own commands, in the order the list shows them. */
export type LocalCommand = "new" | "model" | "think" | "stop" | "info";

/**
 * A `/model` or `/think` answer, shown in the transcript of this browser only (never stored on the relay). It offers
 * the choices as buttons; a tap sets the value (`commands:setConfig`) and the card follows that command to the end.
 */
export type BotCard = {
  id: string;
  kind: ConfigKind;
  createdAt: number;
  state: "choosing" | "applying" | "done" | "failed";
  /** The value being applied, or applied. */
  value?: string;
  commandId?: CommandId;
  error?: string;
  /** What a typed argument matched when it picked nothing: no choice, or more than one. */
  miss?: { arg: string; reason: "none" | "several" };
};

/**
 * What a card needs to know about its session. `models` is its computer's list (`devices:models`, mobile/DESIGN.md
 * "Model and thinking level"), which the bot cards share with the composer's pills.
 */
export type CardSession = Pick<SessionDetail, "model" | "effort" | "deviceName" | "deviceOnline"> & {
  models: readonly ModelChoice[] | null;
};

/** `/name rest of the line` → its parts; anything else → null. */
export function parseSlash(text: string): { name: string; arg: string } | null {
  const match = /^\/([^\s/]+)(?:\s+([\s\S]*))?$/.exec(text.trim());
  if (!match) return null;
  return { name: match[1].toLowerCase(), arg: (match[2] ?? "").trim() };
}

/**
 * By id, name or (a thinking level) its canonical value, case-insensitive: an exact match, else the one choice the
 * argument is a prefix of.
 */
export function matchChoice<T extends { id: string; name: string; value?: string }>(
  choices: readonly T[],
  arg: string,
): { match: T } | { match: null; reason: "none" | "several" } {
  const wanted = arg.trim().toLowerCase();
  const keys = (c: T) => [c.id, c.name, c.value ?? ""].filter(Boolean).map((k) => k.toLowerCase());
  const exact = choices.find((c) => keys(c).includes(wanted));
  if (exact) return { match: exact };
  const prefixed = choices.filter((c) => keys(c).some((k) => k.startsWith(wanted)));
  if (prefixed.length === 1) return { match: prefixed[0] };
  return { match: null, reason: prefixed.length ? "several" : "none" };
}

/** The session's model among its computer's choices (the session names it by id; older crok by name). */
export function currentModel(models: readonly ModelChoice[] | null, model: string | null): ModelChoice | null {
  if (!models || !model) return null;
  const lower = model.toLowerCase();
  return models.find((m) => m.id === model) ?? models.find((m) => m.name.toLowerCase() === lower) ?? null;
}

/** The choices a card offers: the computer's models, or the current model's thinking levels; null while unknown. */
export function cardChoices(session: CardSession, kind: ConfigKind): readonly (ModelChoice | EffortChoice)[] | null {
  if (!session.models) return null;
  if (kind === "model") return session.models;
  return currentModel(session.models, session.model)?.efforts ?? [];
}

/**
 * The id of the choice in use now: the current model, or its thinking level. The session names its level by the
 * canonical value (`high`), which is the level's `value`, or its id when it has none; unset, the model's default (an
 * id).
 */
export function currentValue(session: CardSession, kind: ConfigKind): string | null {
  const model = currentModel(session.models, session.model);
  if (kind === "model") return model?.id ?? session.model;
  if (!session.effort) return model?.defaultEffort ?? null;
  return model?.efforts.find((e) => (e.value ?? e.id) === session.effort)?.id ?? session.effort;
}

/** The canonical thinking levels the dictionary has words for (`effort_<level>`). */
const LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "default"];

/**
 * A thinking level's name: in the reader's language when the computer called it by the plain English word ("High"),
 * else the computer's own name ("Low (4k tokens)"). A bare level the computer doesn't list (offline) by the dictionary.
 */
export function levelName(t: (key: MessageKey) => string, level: { id: string; name?: string; value?: string }): string {
  const canonical = (level.value ?? level.id).toLowerCase();
  const key = `effort_${canonical}` as MessageKey;
  if (!LEVELS.includes(canonical)) return level.name ?? level.id;
  if (level.name === undefined || level.name.toLowerCase() === translate("en", key).toLowerCase()) return t(key);
  return level.name;
}

/** A value's display name: the model's own name, or the level's (see `levelName`); else the id. */
export function choiceName(
  t: (key: MessageKey) => string,
  session: CardSession,
  kind: ConfigKind,
  value: string | null,
): string | null {
  if (!value) return null;
  const choice = cardChoices(session, kind)?.find((c) => c.id === value);
  if (kind === "model") return choice?.name ?? value;
  return levelName(t, choice ?? { id: value });
}

/**
 * The composer's list: the device's own commands first (`/stop` only while a turn runs, `/think` only when the model
 * has thinking levels, neither `/model` nor `/think` before the session opened on its computer), then the session's
 * (`sessions:commands`), without the ones the device's own commands shadow.
 */
export function composerCommands(
  t: (key: MessageKey) => string,
  session: CardSession & Pick<SessionDetail, "status" | "starting">,
  sessionCommands: readonly SlashCommand[] | undefined,
): ComposerCommand[] {
  const efforts = cardChoices(session, "reasoning_effort");
  const local: (ComposerCommand & { name: LocalCommand })[] = [
    { name: "new", description: t("cmd_new"), hint: t("cmd_hint_prompt"), takesArgs: true, local: true },
  ];
  if (!session.starting) {
    local.push({ name: "model", description: t("cmd_model"), hint: t("cmd_hint_name"), takesArgs: true, local: true });
    // Unknown (no models yet): offered, and the card says why there is nothing to pick.
    if (efforts === null || efforts.length > 0) {
      local.push({
        name: "think",
        description: t("cmd_think"),
        hint: t("cmd_hint_level"),
        takesArgs: true,
        local: true,
      });
    }
  }
  if (session.status === "running") {
    local.push({ name: "stop", description: t("cmd_stop"), takesArgs: false, local: true });
  }
  local.push({ name: "info", description: t("cmd_info"), takesArgs: false, local: true });
  const taken = new Set<string>(local.map((c) => c.name));
  const remote = (sessionCommands ?? [])
    .filter((c) => !taken.has(c.name.toLowerCase()))
    .map((c) => ({ name: c.name, description: c.description, hint: c.hint, takesArgs: Boolean(c.hint), local: false }));
  return [...local, ...remote];
}

/**
 * The bot cards of one open session. `apply` sends `commands:setConfig` and resolves to its command id; the caller
 * follows that command (`commands:get`) and calls `settle` once it is done or failed.
 */
export function useBotCards({
  session,
  apply,
  errorText,
  initial,
}: {
  session: CardSession | undefined;
  apply: (kind: ConfigKind, value: string) => Promise<CommandId>;
  errorText: (error: unknown) => string;
  initial?: BotCard[];
}) {
  const [cards, setCards] = useState<BotCard[]>(() => initial ?? []);
  const nextId = useRef(1);

  const patch = (id: string, change: Partial<BotCard>) =>
    setCards((list) => list.map((card) => (card.id === id ? { ...card, ...change } : card)));

  const start = (id: string, kind: ConfigKind, value: string) => {
    patch(id, { state: "applying", value, error: undefined, commandId: undefined });
    apply(kind, value).then(
      (commandId) => patch(id, { commandId }),
      (error) => patch(id, { state: "failed", error: errorText(error) }),
    );
  };

  /** Picking the value in use changes nothing: the card just says so. */
  const pick = (id: string, kind: ConfigKind, value: string) => {
    if (session && value === currentValue(session, kind)) patch(id, { state: "done", value });
    else start(id, kind, value);
  };

  return {
    cards,
    /** `/model` or `/think`: a new card; with an argument that picks one choice, applied at once. */
    open: (kind: ConfigKind, arg?: string) => {
      const id = `card-${nextId.current++}`;
      const card: BotCard = { id, kind, createdAt: Date.now(), state: "choosing" };
      const choices = session ? cardChoices(session, kind) : null;
      const wanted = arg?.trim();
      let picked: string | null = null;
      if (wanted && choices?.length) {
        const found = matchChoice(choices, wanted);
        if (found.match) picked = found.match.id;
        else card.miss = { arg: wanted, reason: found.reason };
      }
      setCards((list) => [...list, card]);
      if (picked) pick(id, kind, picked);
    },
    /** A tap on one of a card's buttons. */
    choose: (id: string, value: string) => {
      const card = cards.find((c) => c.id === id);
      if (!card || card.state === "applying") return;
      pick(id, card.kind, value);
    },
    /** The card's command finished on the computer. */
    settle: (id: string, status: "done" | "failed", error?: string) =>
      patch(id, status === "done" ? { state: "done" } : { state: "failed", error: error || undefined }),
  };
}

/** The command list above the composer (Telegram's command menu): `/name` in bold, its input hint, its description. */
export function CommandPanel({
  id,
  commands,
  active,
  onHover,
  onPick,
}: {
  id: string;
  commands: ComposerCommand[];
  active: number;
  onHover: (index: number) => void;
  onPick: (command: ComposerCommand) => void;
}) {
  const { t } = useI18n();
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    listRef.current?.querySelector<HTMLElement>(`[data-index="${active}"]`)?.scrollIntoView({ block: "nearest" });
  }, [active]);
  return (
    <div
      ref={listRef}
      id={id}
      role="listbox"
      aria-label={t("commands_label")}
      className="scroll-quiet absolute inset-x-0 bottom-full z-20 mb-2 max-h-[min(50vh,21rem)] overflow-y-auto overscroll-contain rounded-2xl border border-line bg-surface py-1.5 shadow-card"
    >
      {commands.map((command, index) => (
        <div
          key={`${command.local ? "local" : "session"}:${command.name}`}
          id={`${id}-${index}`}
          data-index={index}
          role="option"
          aria-selected={index === active}
          // Keeps the focus (and the phone keyboard) in the field.
          onMouseDown={(e) => e.preventDefault()}
          onMouseMove={() => onHover(index)}
          onClick={() => onPick(command)}
          className={`flex cursor-pointer items-baseline gap-3 px-4 py-2 ${index === active ? "bg-hover" : ""} ${
            index > 0 && commands[index - 1].local && !command.local ? "mt-1.5 border-t border-line pt-3" : ""
          }`}
        >
          <span className="shrink-0 text-[14.5px]">
            <span className="font-semibold text-fg">/{command.name}</span>
            {command.hint ? <span className="ml-1.5 text-faint">{command.hint}</span> : null}
          </span>
          <span className="min-w-0 flex-1 truncate text-[13.5px] text-muted">{command.description}</span>
        </div>
      ))}
    </div>
  );
}

/**
 * A bot card in the transcript: "Model for this session" and an inline keyboard (models one per row with their
 * description, thinking levels two per row, the current one ✓). The tapped button spins until the computer applied
 * it; then the card reads "Model: Grok 4 ✓" and the keyboard folds away. A failure shows in the card, buttons stay.
 */
export function BotCardView({
  card,
  session,
  onChoose,
}: {
  card: BotCard;
  session: CardSession;
  onChoose: (value: string) => void;
}) {
  const { t } = useI18n();
  const choices = cardChoices(session, card.kind);
  const current = currentValue(session, card.kind);
  const isModel = card.kind === "model";

  if (card.state === "done") {
    const name = choiceName(t, session, card.kind, card.value ?? current) ?? "—";
    return (
      <div className="max-w-full rounded-2xl rounded-tl-md border border-line bg-surface px-4 py-2.5 text-[15px] text-fg sm:max-w-md">
        <span className="break-words">{t(isModel ? "card_model_done" : "card_effort_done", { name })}</span>
        <CheckIcon
          size={16}
          className="ml-1.5 inline-block -translate-y-px text-accent-text"
          aria-label={t("tick_done")}
        />
      </div>
    );
  }

  let note: string | null = null;
  if (!choices) {
    note = session.deviceOnline
      ? t("card_unavailable", { computer: session.deviceName })
      : t("card_offline", { computer: session.deviceName });
  } else if (!choices.length) note = t("card_no_efforts");
  else if (card.miss) {
    note = t(card.miss.reason === "several" ? "card_ambiguous" : "card_no_match", { arg: card.miss.arg });
  }
  const applying = card.state === "applying";

  return (
    <div className="flex w-full max-w-full flex-col gap-1 sm:max-w-md">
      <div className="rounded-2xl rounded-tl-md border border-line bg-surface px-4 py-2.5 text-[15px] text-fg">
        <p className="font-semibold">{t(isModel ? "card_model_title" : "card_effort_title")}</p>
        {note ? <p className="mt-0.5 text-[13.5px] text-muted">{note}</p> : null}
        {card.state === "failed" ? (
          <p className="mt-1 text-[13.5px] text-danger" role="alert">
            {t("card_failed", { error: card.error ?? t("error_generic") })}
          </p>
        ) : null}
      </div>
      {choices?.length ? (
        <div
          className={`scroll-quiet grid max-h-[22rem] gap-1 overflow-y-auto ${isModel ? "grid-cols-1" : "grid-cols-2"}`}
        >
          {choices.map((choice) => {
            const spinning = applying && card.value === choice.id;
            const selected = choice.id === current;
            return (
              <button
                key={choice.id}
                type="button"
                disabled={applying}
                aria-pressed={selected}
                onClick={() => onChoose(choice.id)}
                className={`flex min-h-10 items-center gap-2 rounded-xl bg-accent-soft px-3.5 py-2 text-accent-text transition-colors hover:bg-accent/20 disabled:cursor-default disabled:hover:bg-accent-soft ${
                  isModel ? "text-left" : "justify-center text-center"
                } ${applying && !spinning ? "opacity-60" : ""}`}
              >
                <span className={isModel ? "min-w-0 flex-1" : "min-w-0"}>
                  <span className="block truncate text-[14px] font-medium">
                    {isModel ? choice.name : levelName(t, choice)}
                  </span>
                  {isModel && choice.description ? (
                    <span className="block truncate text-[12px] text-muted">{choice.description}</span>
                  ) : null}
                </span>
                {spinning ? (
                  <SpinnerIcon size={16} className="shrink-0" />
                ) : selected ? (
                  <CheckIcon size={16} className="shrink-0" aria-label={t("card_current")} />
                ) : null}
              </button>
            );
          })}
        </div>
      ) : null}
    </div>
  );
}
