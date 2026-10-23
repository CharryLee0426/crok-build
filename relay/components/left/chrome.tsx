"use client";

/** The left column's page chrome: a header with a back arrow, the search field, the project picker for New Session. */
import { useEffect, useMemo, useRef } from "react";
import type { ReactNode } from "react";
import { tildePath } from "@/lib/format";
import { ForumAvatar } from "../avatars";
import { useI18n } from "../I18nProvider";
import { ArrowLeftIcon, SearchIcon, XIcon } from "../icons";
import { IconButton } from "../ui";

/** A page's header: back arrow, title and subtitle (or a custom leading part), trailing buttons. */
export function PageHeader({
  onBack,
  title,
  subtitle,
  leading,
  trailing,
}: {
  onBack?: () => void;
  title?: ReactNode;
  subtitle?: ReactNode;
  /** Replaces the title block (the computer switcher on the root page). */
  leading?: ReactNode;
  trailing?: ReactNode;
}) {
  const { t } = useI18n();
  return (
    <header className="flex h-14 shrink-0 items-center gap-1 px-2">
      {onBack ? (
        <IconButton label={t("back")} onClick={onBack} className="h-10 w-10">
          <ArrowLeftIcon size={22} />
        </IconButton>
      ) : null}
      {leading ?? (
        <div className={`min-w-0 flex-1 ${onBack ? "pl-1" : "pl-2"}`}>
          <h2 className="truncate text-[16.5px] font-semibold leading-tight">{title}</h2>
          {subtitle ? <p className="truncate text-[13px] leading-tight text-muted">{subtitle}</p> : null}
        </div>
      )}
      {trailing ? <div className="flex shrink-0 items-center gap-0.5">{trailing}</div> : null}
    </header>
  );
}

/** A text button in a header (Edit, Done). */
export function HeaderTextButton({
  children,
  onClick,
  disabled,
  strong = false,
}: {
  children: ReactNode;
  onClick: () => void;
  disabled?: boolean;
  strong?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={`h-9 rounded-full px-3 text-[14.5px] text-accent-text transition-colors hover:bg-hover disabled:opacity-40 disabled:hover:bg-transparent ${
        strong ? "font-semibold" : ""
      }`}
    >
      {children}
    </button>
  );
}

export function SearchField({
  value,
  onChange,
  placeholder,
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder: string;
}) {
  const { t } = useI18n();
  return (
    <div className="shrink-0 px-3 pb-2">
      <label className="flex h-10 items-center gap-2 rounded-full bg-surface-2 px-3.5 text-faint ring-accent/50 focus-within:bg-surface focus-within:ring-2">
        <SearchIcon size={17} />
        <input
          type="search"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape" && value) {
              e.preventDefault();
              onChange("");
            }
          }}
          placeholder={placeholder}
          aria-label={placeholder}
          className="min-w-0 flex-1 bg-transparent text-[15px] text-fg placeholder:text-faint focus:outline-none [&::-webkit-search-cancel-button]:hidden"
        />
        {value ? (
          <button type="button" onClick={() => onChange("")} aria-label={t("clear_search")} className="text-faint hover:text-fg">
            <XIcon size={16} />
          </button>
        ) : null}
      </label>
    </div>
  );
}

/** An empty page: an icon, a title, a line, an action. */
export function EmptyState({
  icon,
  title,
  children,
  action,
}: {
  icon?: ReactNode;
  title: string;
  children?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col items-center px-8 py-14 text-center">
      {icon ? <div className="mb-3 text-faint">{icon}</div> : null}
      <p className="text-[15px] font-semibold text-fg">{title}</p>
      {children ? <div className="mt-1.5 text-[13.5px] leading-relaxed text-muted">{children}</div> : null}
      {action ? <div className="mt-5">{action}</div> : null}
    </div>
  );
}

export type PickerProject = { key: string; deviceId: string; path: string; name: string; lastActivityAt: number };

/** New Session's first step: which of this computer's projects, most recently active first. */
export function ProjectPicker({
  open,
  projects,
  onPick,
  onClose,
}: {
  open: boolean;
  projects: PickerProject[];
  onPick: (project: PickerProject) => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);
  const sorted = useMemo(() => [...projects].sort((a, b) => b.lastActivityAt - a.lastActivityAt), [projects]);
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
      aria-labelledby="project-picker-title"
      className="m-auto max-h-[min(80dvh,36rem)] w-[min(calc(100vw-24px),26rem)] overflow-hidden rounded-2xl border border-line bg-surface p-0 text-fg shadow-card backdrop:bg-black/40"
    >
      <div className="flex max-h-[min(80dvh,36rem)] flex-col">
        <div className="flex shrink-0 items-start justify-between gap-3 border-b border-line px-5 pb-3 pt-4">
          <div>
            <h2 id="project-picker-title" className="text-base font-semibold">
              {t("menu_new_session")}
            </h2>
            <p className="mt-0.5 text-[13px] text-muted">{t("new_session_choose")}</p>
          </div>
          <IconButton label={t("close")} onClick={onClose} className="-mr-2 -mt-1">
            <XIcon size={18} />
          </IconButton>
        </div>
        <div className="scroll-quiet min-h-0 flex-1 overflow-y-auto p-2">
          {sorted.length === 0 ? (
            <p className="px-3 py-6 text-center text-sm leading-relaxed text-muted">{t("new_session_no_projects")}</p>
          ) : (
            <ul>
              {sorted.map((project) => (
                <li key={project.key}>
                  <button
                    type="button"
                    onClick={() => onPick(project)}
                    className="flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left transition-colors hover:bg-hover"
                  >
                    <ForumAvatar path={project.path} name={project.name} size={40} />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[15px] font-medium">{project.name}</span>
                      <span className="block truncate text-[12.5px] text-muted">{tildePath(project.path)}</span>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </dialog>
  );
}
