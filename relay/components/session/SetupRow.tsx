"use client";

/**
 * Model and thinking level in the composer (mobile/DESIGN.md "Model and thinking level"): the setup row's two pills,
 * the Choose a Model dialog (search, sections by provider) and the thinking-level menu. The same pieces serve a new
 * session (Default until picked) and an open one (a change goes through `commands:setConfig`, spinning until done).
 */
import { useEffect, useMemo, useRef, useState } from "react";
import type { KeyboardEvent as ReactKeyboardEvent, ReactNode, Ref } from "react";
import { filterModels, middleSplit, modelSections } from "@/lib/models";
import type { EffortChoice, ModelChoice } from "@/lib/types";
import { useI18n } from "../I18nProvider";
import { BrainIcon, CheckIcon, ChevronDownIcon, ChipIcon, SearchIcon, SpinnerIcon, XIcon } from "../icons";
import { MenuList, Popover, useMenu } from "../menu";
import type { MenuItem } from "../menu";
import { IconButton } from "../ui";
import { levelName } from "./BotCommands";

/** A pill of the setup row: glyph, value (the model's shortened in the middle), chevron or spinner. */
function Pill({
  icon,
  label,
  title,
  busy = false,
  dimmed = false,
  middle = false,
  expanded,
  onClick,
  pillRef,
}: {
  icon: ReactNode;
  label: string;
  title: string;
  busy?: boolean;
  dimmed?: boolean;
  middle?: boolean;
  expanded?: boolean;
  onClick: (el: HTMLButtonElement) => void;
  pillRef?: Ref<HTMLButtonElement>;
}) {
  const [head, tail] = middle ? middleSplit(label) : [label, ""];
  return (
    <button
      ref={pillRef}
      type="button"
      title={`${title}: ${label}`}
      aria-label={`${title}: ${label}`}
      aria-haspopup={expanded === undefined ? "dialog" : "menu"}
      aria-expanded={expanded}
      aria-busy={busy || undefined}
      onClick={(e) => {
        if (!busy) onClick(e.currentTarget);
      }}
      className={`flex h-[30px] min-w-0 items-center gap-1.5 rounded-full border border-line bg-surface pl-2.5 pr-2 text-[13px] font-medium shadow-sm transition-colors hover:bg-surface-2 ${
        middle ? "max-w-[60%]" : "max-w-[40%] shrink-0"
      } ${dimmed ? "text-muted" : "text-fg"} ${busy ? "cursor-default" : ""}`}
    >
      <span className="shrink-0 text-muted">{icon}</span>
      <span className="flex min-w-0 whitespace-nowrap">
        <span className="truncate">{head}</span>
        {tail ? <span className="shrink-0">{tail}</span> : null}
      </span>
      {busy ? (
        <SpinnerIcon size={13} className="shrink-0 text-muted" />
      ) : (
        <ChevronDownIcon size={13} className="shrink-0 text-muted" />
      )}
    </button>
  );
}

export type SetupRowProps = {
  /** The model pill's text; null: no pill. */
  model: string | null;
  modelBusy?: boolean;
  /** The computer offers no list (an older crok): dimmed, and a tap explains. */
  modelDimmed?: boolean;
  onModel: () => void;
  /** The thinking pill's text; null: the model has no levels. */
  effort: string | null;
  effortBusy?: boolean;
  /** The thinking menu's items. */
  effortItems: MenuItem[];
};

/** Two pills above the input row, left-aligned. */
export function SetupRow({ model, modelBusy, modelDimmed, onModel, effort, effortBusy, effortItems }: SetupRowProps) {
  const { t } = useI18n();
  const menu = useMenu();
  const effortRef = useRef<HTMLButtonElement>(null);
  if (model === null) return null;
  return (
    <div className="mb-2 flex min-w-0 items-center gap-2">
      <Pill icon={<ChipIcon size={15} />} label={model} title={t("info_model")} busy={modelBusy} dimmed={modelDimmed} middle onClick={onModel} />
      {effort !== null ? (
        <Pill
          pillRef={effortRef}
          icon={<BrainIcon size={15} />}
          label={effort}
          title={t("info_effort")}
          busy={effortBusy}
          expanded={menu.open}
          onClick={(el) => (menu.open ? menu.close() : menu.fromElement(el))}
        />
      ) : null}
      {menu.anchor ? (
        <Popover anchor={menu.anchor} onClose={menu.close} placement="top-start" ignore={effortRef} label={t("info_effort")}>
          <MenuList items={effortItems} onDone={menu.close} />
        </Popover>
      ) : null}
    </div>
  );
}

/** The thinking menu's items: (in a new session Default first) the model's levels, a check on the current one. */
export function effortMenuItems(
  t: ReturnType<typeof useI18n>["t"],
  efforts: readonly EffortChoice[],
  currentId: string | null,
  onPick: (id: string | null) => void,
  withDefault: boolean,
): MenuItem[] {
  return [
    ...(withDefault ? [{ label: t("setup_default"), checked: currentId === null, onSelect: () => onPick(null) }] : []),
    ...efforts.map<MenuItem>((effort) => ({
      label: levelName(t, effort),
      detail: effort.description,
      checked: effort.id === currentId,
      onSelect: () => onPick(effort.id),
    })),
  ];
}

/**
 * Choose a Model: a centred dialog, 480 px wide, with a search field and the computer's models in sections by provider
 * (a new session's first row is Default). Arrow keys move, Enter picks.
 */
export function ModelDialog({
  open,
  models,
  currentId,
  computer,
  isNew,
  onPick,
  onClose,
}: {
  open: boolean;
  models: readonly ModelChoice[];
  /** The current model's id; null: Default (new sessions). */
  currentId: string | null;
  computer: string;
  isNew: boolean;
  onPick: (id: string | null) => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const ref = useRef<HTMLDialogElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) {
      setQuery("");
      dialog.showModal();
      searchRef.current?.focus();
      // The current model in view.
      requestAnimationFrame(() => {
        listRef.current?.querySelector<HTMLElement>('[aria-selected="true"]')?.scrollIntoView({ block: "center" });
      });
    }
    if (!open && dialog.open) dialog.close();
  }, [open]);

  const filtered = useMemo(() => filterModels(models, query), [models, query]);
  const sections = useMemo(() => modelSections(filtered, computer), [filtered, computer]);
  const showDefault = isNew && !query.trim();
  /** The rows in order, for the arrow keys: Default (null) first when shown. */
  const order = useMemo(() => [...(showDefault ? [null] : []), ...sections.flatMap((s) => s.models.map((m) => m.id))], [showDefault, sections]);

  useEffect(() => {
    // Start on the current model; after a search, on the first result.
    const at = query.trim() ? 0 : Math.max(0, order.indexOf(currentId));
    setActive(at);
  }, [query, order, currentId]);

  useEffect(() => {
    listRef.current?.querySelector<HTMLElement>(`[data-row="${active}"]`)?.scrollIntoView({ block: "nearest" });
  }, [active]);

  const onKeyDown = (e: ReactKeyboardEvent) => {
    if (!order.length) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      setActive((a) => (a + (e.key === "ArrowDown" ? 1 : -1) + order.length) % order.length);
    } else if (e.key === "Enter" && !e.nativeEvent.isComposing) {
      e.preventDefault();
      onPick(order[active] ?? null);
    }
  };

  let index = 0;
  const row = (id: string | null, name: string, detail: string | undefined, sub: string | undefined) => {
    const at = index++;
    const current = id === currentId;
    return (
      <div
        key={id ?? "default"}
        role="option"
        aria-selected={current}
        data-row={at}
        onMouseMove={() => setActive(at)}
        onClick={() => onPick(id)}
        className={`flex cursor-pointer items-start gap-3 rounded-xl px-3 py-2 ${at === active ? "bg-hover" : ""}`}
      >
        <span className="min-w-0 flex-1">
          <span className={`block truncate text-[15px] ${current ? "font-semibold" : ""}`}>{name}</span>
          {sub ? <span className="block truncate font-mono text-[12px] text-muted">{sub}</span> : null}
          {detail ? <span className="line-clamp-2 text-[12.5px] leading-snug text-muted">{detail}</span> : null}
        </span>
        {current ? <CheckIcon size={18} className="mt-0.5 shrink-0 text-accent-text" /> : null}
      </div>
    );
  };

  return (
    <dialog
      ref={ref}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
      aria-labelledby="model-dialog-title"
      className="m-auto h-[min(calc(100dvh-32px),40rem)] w-[min(calc(100vw-24px),480px)] max-w-none overflow-hidden rounded-2xl border border-line bg-surface p-0 text-fg shadow-card backdrop:bg-black/40"
    >
      {/* The rows only while open: a closed dialog shouldn't re-render ~500 models with every transcript update. */}
      {open ? (
      <div className="flex h-full flex-col" onKeyDown={onKeyDown}>
        <div className="flex shrink-0 items-center gap-2 px-4 pb-2 pt-3">
          <h2 id="model-dialog-title" className="min-w-0 flex-1 truncate text-[17px] font-semibold">
            {t("choose_model")}
          </h2>
          <IconButton label={t("cancel")} onClick={onClose} className="-mr-1.5">
            <XIcon size={19} />
          </IconButton>
        </div>
        <div className="shrink-0 px-4 pb-2">
          <label className="flex h-10 items-center gap-2 rounded-full bg-surface-2 px-3.5 text-faint ring-accent/50 focus-within:ring-2">
            <SearchIcon size={17} />
            <input
              ref={searchRef}
              type="search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder={t("search_models")}
              aria-label={t("search_models")}
              aria-controls="model-dialog-list"
              className="min-w-0 flex-1 bg-transparent text-[15px] text-fg placeholder:text-faint focus:outline-none [&::-webkit-search-cancel-button]:hidden"
            />
            {query ? (
              <button type="button" onClick={() => setQuery("")} aria-label={t("clear_search")} className="text-faint hover:text-fg">
                <XIcon size={16} />
              </button>
            ) : null}
          </label>
        </div>
        <div
          ref={listRef}
          id="model-dialog-list"
          role="listbox"
          aria-label={t("choose_model")}
          className="scroll-quiet min-h-0 flex-1 overflow-y-auto overscroll-contain px-2 pb-3"
        >
          {showDefault ? row(null, t("setup_default"), t("computer_own_choice", { computer }), undefined) : null}
          {sections.map((section) => (
            <section key={section.title} aria-label={section.title}>
              <h3 className="sticky top-0 z-10 bg-surface px-3 pb-1 pt-3 text-[12.5px] font-semibold uppercase tracking-wide text-muted">
                {section.title}
              </h3>
              {section.models.map((model) =>
                row(model.id, model.name || model.id, model.description, model.name && model.name !== model.id ? model.id : undefined),
              )}
            </section>
          ))}
          {!sections.length && !showDefault ? <p className="px-3 py-10 text-center text-[14px] text-muted">{t("no_results")}</p> : null}
          {!isNew && sections.length ? (
            <p className="px-3 pt-3 text-[12.5px] leading-relaxed text-muted">{t("model_changes_next")}</p>
          ) : null}
        </div>
      </div>
      ) : null}
    </dialog>
  );
}
