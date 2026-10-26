"use client";

/**
 * Profile and its pages in the left column (mobile/DESIGN.md "Profile", "Appearance", "Web"): the account, its
 * computers, Devices, Appearance (session themes, a photo, color mode), Language, the version, the developer's links,
 * Sign Out. Telegram's Settings layout: grouped rows with coloured square icons.
 */
import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { describeBrowser } from "@/lib/browser";
import type { Computer } from "@/lib/computers";
import { LANG_NAMES, LANGS } from "@/lib/i18n";
import type { LangChoice } from "@/lib/i18n";
import { THEME_PHOTO, THEMES, themeById, themeVars } from "@/lib/themes";
import type { SessionTheme } from "@/lib/themes";
import { AccountAvatar, ComputerAvatar } from "../avatars";
import { DevicesView } from "../Devices";
import { useI18n } from "../I18nProvider";
import {
  BrushIcon,
  CheckIcon,
  ChevronRightIcon,
  DevicesIcon,
  DoubleCheckIcon,
  GitHubMark,
  GlobeIcon,
  InfoIcon,
  PhotoIcon,
  PlusIcon,
  SpinnerIcon,
  XIcon,
  XLogo,
} from "../icons";
import { SessionBackground } from "../SessionBackground";
import { useResolvedDark, useSettings } from "../Settings";
import type { ColorMode } from "../Settings";
import { useToast } from "../Toast";
import { PageHeader } from "./chrome";
import { UnreadBadge } from "./rows";
import { ComputerStatus } from "./SessionsPages";
import type { LeftActions, LeftData } from "./types";

export const GITHUB_URL = "https://github.com/CharryLee0426";
export const X_URL = "https://x.com/CharryLee426";

/** Telegram's settings icon colours. */
const ICON_COLORS = { orange: "#F09A37", blue: "#3D8BF2", purple: "#A65EEB", grey: "#8E8E93", github: "#24292F", x: "#000000" };

function SquareIcon({ color, children }: { color: string; children: ReactNode }) {
  return (
    <span
      className="flex h-[29px] w-[29px] shrink-0 items-center justify-center rounded-[7px] text-white"
      style={{ background: color, boxShadow: color === "#000000" || color === "#24292F" ? "inset 0 0 0 0.5px rgb(255 255 255 / 0.18)" : undefined }}
      aria-hidden="true"
    >
      {children}
    </span>
  );
}

function Group({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section className="mt-5">
      {title ? <h3 className="mb-1.5 px-4 text-[12.5px] font-medium uppercase tracking-wide text-muted">{title}</h3> : null}
      <ul className="overflow-hidden rounded-xl bg-surface">{children}</ul>
    </section>
  );
}

/** A row: icon, then the title with an inset hairline above it (not above the first row). */
function Row({
  icon,
  title,
  detail,
  trailing,
  chevron,
  onClick,
  href,
  external,
  tone,
  selected,
}: {
  icon?: ReactNode;
  title: ReactNode;
  detail?: ReactNode;
  trailing?: ReactNode;
  chevron?: boolean;
  onClick?: () => void;
  href?: string;
  external?: boolean;
  tone?: "accent" | "danger";
  selected?: boolean;
}) {
  const inner = (
    <>
      {icon ? <span className="flex w-8 shrink-0 justify-center">{icon}</span> : null}
      <span className="flex min-h-11 min-w-0 flex-1 items-center gap-2 border-t border-line py-1.5 pr-3 group-first/row:border-t-0">
        <span className="min-w-0 flex-1">
          <span
            className={`block truncate text-[15px] ${tone === "accent" ? "text-accent-text" : tone === "danger" ? "text-danger" : "text-fg"}`}
          >
            {title}
          </span>
          {detail ? <span className="block truncate text-[13px]">{detail}</span> : null}
        </span>
        {trailing}
        {selected ? <CheckIcon size={18} className="shrink-0 text-accent-text" /> : null}
        {chevron ? <ChevronRightIcon size={16} className="shrink-0 text-faint" /> : null}
      </span>
    </>
  );
  const className = `flex w-full items-center gap-3 pl-3 text-left ${onClick || href ? "transition-colors hover:bg-hover" : ""}`;
  return (
    <li className="group/row">
      {href ? (
        external ? (
          <a href={href} target="_blank" rel="noopener noreferrer" className={className}>
            {inner}
          </a>
        ) : (
          <Link href={href} className={className}>
            {inner}
          </Link>
        )
      ) : onClick ? (
        <button type="button" onClick={onClick} aria-pressed={selected} className={className}>
          {inner}
        </button>
      ) : (
        <div className={className}>{inner}</div>
      )}
    </li>
  );
}

function PageBody({ children }: { children: ReactNode }) {
  return <div className="scroll-quiet min-h-0 flex-1 overflow-y-auto bg-canvas px-3 pb-8">{children}</div>;
}

export function ProfilePage({
  data,
  actions,
  computers,
  selectedId,
  onSelectComputer,
  onBack,
  onOpen,
}: {
  data: LeftData;
  actions: LeftActions;
  computers: Computer[];
  selectedId: string | null;
  onSelectComputer: (id: string) => void;
  onBack: () => void;
  onOpen: (page: "devices" | "appearance" | "language") => void;
}) {
  const { t, choice } = useI18n();
  const account = data.account;
  const name = account?.name ?? account?.email ?? t("your_account");
  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader onBack={onBack} title={t("profile")} />
      <PageBody>
        <div className="flex flex-col items-center px-4 pt-5 text-center">
          <AccountAvatar name={name} imageUrl={account?.imageUrl} size={96} />
          <h3 className="mt-3 max-w-full truncate text-[21px] font-semibold leading-tight">{name}</h3>
          {account?.email && account.name ? <p className="mt-1 max-w-full truncate text-[14px] text-muted">{account.email}</p> : null}
        </div>

        <Group>
          {computers.map((computer) => (
            <Row
              key={computer.id}
              icon={<ComputerAvatar id={computer.id} name={computer.name} online={computer.online} size={32} />}
              title={computer.name}
              detail={<ComputerStatus computer={computer} now={data.now} />}
              trailing={computer.unread > 0 ? <UnreadBadge count={computer.unread} /> : null}
              selected={computer.id === selectedId}
              onClick={() => onSelectComputer(computer.id)}
            />
          ))}
          <Row
            icon={<PlusIcon size={22} strokeWidth={2.2} className="text-accent-text" />}
            title={t("link_computer")}
            tone="accent"
            href="/link"
          />
        </Group>

        <Group>
          <Row
            icon={
              <SquareIcon color={ICON_COLORS.orange}>
                <DevicesIcon size={18} strokeWidth={2} />
              </SquareIcon>
            }
            title={t("nav_devices")}
            trailing={<span className="text-[15px] text-muted">{data.devices?.length ?? ""}</span>}
            chevron
            onClick={() => onOpen("devices")}
          />
          <Row
            icon={
              <SquareIcon color={ICON_COLORS.blue}>
                <BrushIcon size={18} strokeWidth={2} />
              </SquareIcon>
            }
            title={t("appearance")}
            chevron
            onClick={() => onOpen("appearance")}
          />
          <Row
            icon={
              <SquareIcon color={ICON_COLORS.purple}>
                <GlobeIcon size={18} strokeWidth={2} />
              </SquareIcon>
            }
            title={t("footer_language")}
            trailing={<span className="text-[15px] text-muted">{choice === "auto" ? t("lang_auto") : LANG_NAMES[choice]}</span>}
            chevron
            onClick={() => onOpen("language")}
          />
        </Group>

        <Group>
          <Row
            icon={
              <SquareIcon color={ICON_COLORS.grey}>
                <InfoIcon size={18} strokeWidth={2.2} />
              </SquareIcon>
            }
            title={t("version")}
            trailing={<span className="text-[15px] tabular-nums text-muted">{data.version}</span>}
          />
          <Row
            icon={
              <SquareIcon color={ICON_COLORS.github}>
                <GitHubMark size={17} />
              </SquareIcon>
            }
            title={t("contact_github")}
            href={GITHUB_URL}
            external
          />
          <Row
            icon={
              <SquareIcon color={ICON_COLORS.x}>
                <XLogo size={15} />
              </SquareIcon>
            }
            title={t("contact_x")}
            href={X_URL}
            external
          />
        </Group>

        <Group>
          <Row title={t("profile_sign_out")} tone="danger" onClick={actions.signOut} />
        </Group>
      </PageBody>
    </div>
  );
}

export function DevicesPage({ data, actions, onBack }: { data: LeftData; actions: LeftActions; onBack: () => void }) {
  const { t } = useI18n();
  const [browserLabel, setBrowserLabel] = useState("");
  useEffect(() => setBrowserLabel(describeBrowser(navigator.userAgent)), []);
  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader onBack={onBack} title={t("nav_devices")} />
      <PageBody>
        <DevicesView devices={data.devices} browserLabel={browserLabel} now={data.now} actions={actions.devices} compact />
      </PageBody>
    </div>
  );
}

export function LanguagePage({ onBack }: { onBack: () => void }) {
  const { t, choice, setChoice } = useI18n();
  const choices: { value: LangChoice; label: string }[] = [
    { value: "auto", label: t("lang_auto") },
    ...LANGS.map((lang) => ({ value: lang as LangChoice, label: LANG_NAMES[lang] })),
  ];
  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader onBack={onBack} title={t("footer_language")} />
      <PageBody>
        <Group>
          {choices.map((entry) => (
            <Row key={entry.value} title={entry.label} selected={entry.value === choice} onClick={() => setChoice(entry.value)} />
          ))}
        </Group>
      </PageBody>
    </div>
  );
}

/** The person's bubble's time and ✓✓, in the theme's colour. */
function PreviewMeta() {
  return (
    <span className="ml-2 inline-flex translate-y-0.5 items-center gap-0.5 text-[11px] text-bubble-user-meta tabular-nums">
      9:41
      <DoubleCheckIcon size={14} />
    </span>
  );
}

/** Appearance's preview: the session background with an exchange in the theme's colours. */
function ThemePreview({ theme }: { theme: SessionTheme }) {
  const { t } = useI18n();
  const dark = useResolvedDark();
  const settings = useSettings();
  const wallpaper = theme.kind === "pattern" || (theme.id === THEME_PHOTO && Boolean(settings.photoUrl));
  const style = themeVars(theme, dark) as CSSProperties;
  return (
    <div
      className="relative mt-4 flex min-h-[190px] flex-col justify-center gap-2 overflow-hidden rounded-2xl p-3.5 text-[14px]"
      style={style}
      data-wallpaper={wallpaper ? "" : undefined}
    >
      <SessionBackground themeId={theme.id} />
      <span className="svc relative self-center rounded-full px-2.5 py-0.5 text-[12px] font-semibold">{t("today")}</span>
      <div className="relative mr-12 self-start rounded-[18px] rounded-bl-md bg-surface px-3 py-2 text-fg shadow-sm">
        {t("theme_preview_agent")}
      </div>
      <div className="relative ml-12 self-end rounded-[18px] rounded-br-md bg-bubble-user px-3 py-2 text-bubble-user-fg shadow-sm">
        {t("theme_preview_user")}
        <PreviewMeta />
      </div>
    </div>
  );
}

function ThemeCard({ theme, selected, onSelect }: { theme: SessionTheme; selected: boolean; onSelect: () => void }) {
  const { t } = useI18n();
  const dark = useResolvedDark();
  const style = themeVars(theme, dark) as CSSProperties;
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-label={t(theme.name)}
      aria-pressed={selected}
      title={t(theme.name)}
      className={`shrink-0 rounded-[15px] p-[3px] ring-2 transition-shadow ${selected ? "ring-accent" : "ring-transparent hover:ring-line-strong"}`}
    >
      <span
        className="relative flex h-[116px] w-[84px] flex-col overflow-hidden rounded-[12px] p-2.5 ring-1 ring-line"
        style={style}
      >
        <SessionBackground themeId={theme.id} patternScale={0.5} />
        <span className="relative h-3.5 w-11 rounded-full bg-surface" />
        <span className="relative mt-1.5 h-3.5 w-11 self-end rounded-full bg-bubble-user" />
        <span className="relative mt-auto flex justify-center text-[22px] leading-none">
          {theme.kind === "plain" ? (
            <XIcon size={20} strokeWidth={2.4} className="text-muted" />
          ) : theme.kind === "photo" ? (
            <PhotoIcon size={20} strokeWidth={2.2} className="text-white drop-shadow" />
          ) : (
            theme.emoji
          )}
        </span>
      </span>
    </button>
  );
}

export function AppearancePage({ onBack }: { onBack: () => void }) {
  const { t } = useI18n();
  const settings = useSettings();
  const toast = useToast();
  const fileRef = useRef<HTMLInputElement>(null);
  const stripRef = useRef<HTMLDivElement>(null);
  const [saving, setSaving] = useState(false);
  const selected = themeById(settings.sessionTheme);
  const themes = THEMES.filter((theme) => theme.kind !== "photo" || settings.photoUrl);
  const modes: { value: ColorMode; label: string }[] = [
    { value: "system", label: t("color_system") },
    { value: "light", label: t("color_light") },
    { value: "dark", label: t("color_dark") },
  ];

  // The selected card in view when the page opens.
  useEffect(() => {
    const strip = stripRef.current;
    const card = strip?.querySelector<HTMLElement>('[aria-pressed="true"]');
    if (strip && card) strip.scrollLeft = card.offsetLeft - strip.clientWidth / 2 + card.offsetWidth / 2;
    // Once.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="flex h-full min-h-0 flex-col">
      <PageHeader onBack={onBack} title={t("appearance")} />
      <PageBody>
        <ThemePreview theme={selected.kind === "photo" && !settings.photoUrl ? themeById("none") : selected} />

        <section className="mt-5">
          <h3 className="mb-1.5 px-4 text-[12.5px] font-medium uppercase tracking-wide text-muted">{t("session_theme")}</h3>
          <div className="overflow-hidden rounded-xl bg-surface">
            <div ref={stripRef} className="scroll-quiet flex gap-1.5 overflow-x-auto px-2.5 pb-1 pt-2.5">
              {themes.map((theme) => (
                <ThemeCard
                  key={theme.id}
                  theme={theme}
                  selected={theme.id === selected.id}
                  onSelect={() => settings.setSessionTheme(theme.id)}
                />
              ))}
            </div>
            <p className="pb-2.5 pt-1 text-center text-[13.5px] font-medium text-muted">{t(selected.name)}</p>
          </div>
        </section>

        <Group>
          <Row
            icon={
              <SquareIcon color={ICON_COLORS.blue}>
                <PhotoIcon size={18} strokeWidth={2} />
              </SquareIcon>
            }
            title={t("choose_photo")}
            trailing={saving ? <SpinnerIcon size={16} className="text-muted" /> : null}
            onClick={() => fileRef.current?.click()}
          />
          {selected.id === THEME_PHOTO && settings.photoUrl ? (
            <li className="group/row">
              <label className="flex w-full cursor-pointer items-center gap-3 pl-3">
                <span className="flex w-8 shrink-0 justify-center">
                  <SquareIcon color={ICON_COLORS.grey}>
                    <span className="h-3.5 w-3.5 rounded-full bg-white/90 blur-[2px]" />
                  </SquareIcon>
                </span>
                <span className="flex min-h-11 min-w-0 flex-1 items-center gap-2 border-t border-line py-1.5 pr-3">
                  <span className="min-w-0 flex-1 truncate text-[15px]">{t("blur")}</span>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={settings.blur}
                    onChange={(e) => settings.setBlur(e.target.checked)}
                    className="switch"
                  />
                </span>
              </label>
            </li>
          ) : null}
        </Group>
        <input
          ref={fileRef}
          type="file"
          accept="image/*"
          className="hidden"
          onChange={(e) => {
            const file = e.target.files?.[0];
            e.target.value = "";
            if (!file) return;
            setSaving(true);
            void settings.choosePhoto(file).then((ok) => {
              setSaving(false);
              if (!ok) toast.show(t("photo_failed"), "error");
            });
          }}
        />

        <section className="mt-5">
          <h3 className="mb-1.5 px-4 text-[12.5px] font-medium uppercase tracking-wide text-muted">{t("color_mode")}</h3>
          <div role="radiogroup" aria-label={t("color_mode")} className="flex gap-1 rounded-xl bg-surface p-1">
            {modes.map((mode) => (
              <button
                key={mode.value}
                type="button"
                role="radio"
                aria-checked={settings.colorMode === mode.value}
                onClick={() => settings.setColorMode(mode.value)}
                className={`h-9 flex-1 rounded-lg text-[14px] transition-colors ${
                  settings.colorMode === mode.value ? "bg-accent font-medium text-accent-fg" : "text-fg hover:bg-hover"
                }`}
              >
                {mode.label}
              </button>
            ))}
          </div>
        </section>
      </PageBody>
    </div>
  );
}
