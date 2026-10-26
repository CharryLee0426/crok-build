"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import type { MessageKey } from "@/lib/i18n";
import type { ProjectGroup, SessionRow } from "@/lib/types";
import { AccountAvatar, ComputerAvatar } from "./avatars";
import { Footer } from "./chrome";
import { useI18n } from "./I18nProvider";
import { BoltIcon, ChevronDownIcon, ComputerIcon, PhoneIcon, SearchIcon, ShieldIcon, SparkIcon } from "./icons";
import { ForumRow } from "./left/rows";
import { ButtonLink, Code, CrokLogo } from "./ui";

/** The landing page's picture of the app: one computer's projects as groups with topics (mobile/DESIGN.md "Web"). */
function demoGroups(t: (key: MessageKey) => string): { group: ProjectGroup; time: string }[] {
  const deviceId = "demo-device" as SessionRow["deviceId"];
  const row = (
    id: string,
    cwd: string,
    fields: Pick<SessionRow, "title" | "status" | "preview" | "unread"> & Partial<SessionRow>,
  ): SessionRow => ({
    _id: id as SessionRow["_id"],
    sessionId: "demo",
    cwd,
    model: "grok-code",
    gitBranch: null,
    usage: null,
    app: "tui",
    online: true,
    deviceId,
    deviceName: "MacBook Pro",
    deviceOnline: true,
    previewKind: "assistant",
    lastActivityAt: 0,
    pinned: false,
    archived: false,
    plan: null,
    projectKey: `demo-device:${cwd}`,
    projectPath: cwd,
    projectName: cwd.split("/").pop() ?? cwd,
    historyState: null,
    starting: false,
    startedFrom: null,
    ...fields,
  });
  const group = (cwd: string, sessions: SessionRow[]): ProjectGroup => ({
    key: `demo-device:${cwd}`,
    deviceId,
    deviceName: "MacBook Pro",
    deviceOnline: true,
    deviceLastSeenAt: null,
    path: cwd,
    name: cwd.split("/").pop() ?? cwd,
    placed: false,
    lastActivityAt: 0,
    sessions,
  });
  const web = "/Users/me/code/web-app";
  const settings = "/Users/me/code/settings-ui";
  const billing = "/Users/me/code/billing-service";
  return [
    {
      time: "09:41",
      group: group(web, [
        row("demo1", web, { title: t("demo_title_1"), status: "running", preview: t("demo_preview_1"), unread: 0 }),
        row("demo4", web, { title: t("demo_title_3"), status: "idle", preview: t("demo_preview_3"), unread: 0 }),
      ]),
    },
    {
      time: "09:12",
      group: group(settings, [
        row("demo2", settings, { title: t("demo_title_2"), status: "idle", preview: t("demo_preview_2"), unread: 2 }),
      ]),
    },
    {
      time: "08:30",
      group: group(billing, [
        row("demo3", billing, { title: t("demo_title_3"), status: "idle", preview: t("demo_preview_3"), unread: 0 }),
      ]),
    },
  ];
}

function Feature({ icon, title, children }: { icon: ReactNode; title: string; children: ReactNode }) {
  return (
    <div className="rounded-2xl border border-line bg-surface p-5">
      <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-accent-soft text-accent-text">{icon}</div>
      <h3 className="mt-4 text-[15px] font-semibold">{title}</h3>
      <p className="mt-1.5 text-sm leading-relaxed text-muted">{children}</p>
    </div>
  );
}

function Step({ n, title, children }: { n: number; title: string; children: ReactNode }) {
  return (
    <li className="flex gap-4">
      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-accent text-sm font-semibold text-accent-fg">
        {n}
      </span>
      <div className="pt-1">
        <h3 className="text-[15px] font-semibold">{title}</h3>
        <p className="mt-1 text-sm leading-relaxed text-muted">{children}</p>
      </div>
    </li>
  );
}

/** `/` for visitors who are not signed in: what remote control is, how to start, and the way in. */
export function Landing() {
  const { t, tx } = useI18n();
  const groups = demoGroups(t);
  const cmd = <Code>crok remote login</Code>;
  return (
    <div className="flex min-h-dvh flex-col">
      <header className="mx-auto flex h-16 w-full max-w-6xl items-center justify-between px-4 sm:px-6">
        <Link href="/" className="flex items-center">
          <CrokLogo size={26} name={t("app_name")} />
        </Link>
        <ButtonLink href="/sign-in" size="sm" tone="secondary">
          {t("sign_in")}
        </ButtonLink>
      </header>

      <main className="flex-1">
        <section className="mx-auto grid w-full max-w-6xl grid-cols-1 items-center gap-12 px-4 pb-16 pt-10 sm:px-6 lg:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)] lg:pt-16">
          <div>
            <p className="text-sm font-semibold text-accent-text">{t("landing_eyebrow")}</p>
            <h1 className="mt-3 text-4xl font-semibold leading-[1.1] tracking-tight sm:text-5xl">{t("landing_title")}</h1>
            <p className="mt-5 max-w-xl text-[17px] leading-relaxed text-muted">{t("landing_lead")}</p>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <ButtonLink href="/sign-in" tone="primary" size="lg">
                {t("sign_in_cta")}
              </ButtonLink>
              <a href="#start" className="px-2 text-sm font-medium text-muted hover:text-fg">
                {t("landing_how_title")} ↓
              </a>
            </div>
          </div>

          <div className="relative" aria-hidden="true">
            <div className="absolute -inset-6 -z-10 rounded-[2.5rem] bg-accent-soft/60 blur-2xl" />
            <div className="pointer-events-none mx-auto max-w-md select-none overflow-hidden rounded-3xl border border-line bg-surface shadow-card" inert>
              <div className="flex items-center gap-2.5 px-4 pb-2 pt-3.5">
                <ComputerAvatar id="demo-device" name="MacBook Pro" online size={36} />
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-1 text-[15.5px] font-semibold leading-tight">
                    MacBook Pro
                    <ChevronDownIcon size={15} className="text-muted" />
                  </span>
                  <span className="block text-[13px] leading-tight text-accent-text">{t("device_online")}</span>
                </span>
                <AccountAvatar name="Crok" size={32} />
              </div>
              <div className="px-4 pb-2">
                <div className="flex h-10 items-center gap-2 rounded-full bg-surface-2 px-3.5 text-[15px] text-faint">
                  <SearchIcon size={17} />
                  {t("search_sessions")}
                </div>
              </div>
              <ul className="px-1.5 pb-2">
                {groups.map(({ group, time }) => (
                  <ForumRow key={group.key} group={group} now={0} timeText={time} onOpen={() => {}} menu={[]} />
                ))}
              </ul>
            </div>
          </div>
        </section>

        <section className="mx-auto grid w-full max-w-6xl grid-cols-1 gap-4 px-4 pb-16 sm:grid-cols-2 sm:px-6 lg:grid-cols-4">
          <Feature icon={<ComputerIcon size={20} />} title={t("feat_all_title")}>
            {t("feat_all")}
          </Feature>
          <Feature icon={<SparkIcon size={20} />} title={t("feat_live_title")}>
            {t("feat_live")}
          </Feature>
          <Feature icon={<BoltIcon size={20} />} title={t("feat_steer_title")}>
            {t("feat_steer")}
          </Feature>
          <Feature icon={<ShieldIcon size={20} />} title={t("feat_control_title")}>
            {t("feat_control")}
          </Feature>
        </section>

        <section id="start" className="mx-auto w-full max-w-6xl scroll-mt-6 px-4 pb-20 sm:px-6">
          <div className="grid grid-cols-1 gap-6 rounded-3xl border border-line bg-surface p-6 sm:p-10 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
            <div>
              <h2 className="text-2xl font-semibold tracking-tight">{t("landing_how_title")}</h2>
              <ol className="mt-6 flex flex-col gap-6">
                <Step n={1} title={t("landing_step1_title")}>
                  {t("landing_step1")}
                </Step>
                <Step n={2} title={t("landing_step2_title")}>
                  {tx("landing_step2", { cmd })}
                </Step>
                <Step n={3} title={t("landing_step3_title")}>
                  {t("landing_step3")}
                </Step>
              </ol>
              <div className="mt-8">
                <ButtonLink href="/sign-in" tone="primary">
                  {t("sign_in_cta")}
                </ButtonLink>
              </div>
            </div>
            <div className="flex flex-col rounded-2xl bg-surface-2 p-6 lg:self-center">
              <PhoneIcon size={28} className="text-accent-text" />
              <h3 className="mt-3 text-[15px] font-semibold">{t("landing_phone_title")}</h3>
              <p className="mt-1.5 text-sm leading-relaxed text-muted">{t("landing_phone")}</p>
            </div>
          </div>
        </section>
      </main>

      <Footer className="mx-auto w-full max-w-6xl border-t border-line" />
    </div>
  );
}
