"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import type { MessageKey } from "@/lib/i18n";
import type { SessionRow } from "@/lib/types";
import { Footer } from "./chrome";
import { useI18n } from "./I18nProvider";
import { BoltIcon, ChatsIcon, ComputerIcon, PhoneIcon, ShieldIcon, SparkIcon } from "./icons";
import { SessionRowView } from "./SessionList";
import { ButtonLink, Code, CrokLogo } from "./ui";

function demoRows(t: (key: MessageKey) => string): { row: SessionRow; time: string }[] {
  const base = {
    sessionId: "demo",
    model: "grok-code",
    app: "tui" as const,
    deviceId: "demo-device" as SessionRow["deviceId"],
    deviceOnline: true,
    archived: false,
    plan: null,
    lastActivityAt: 0,
    historyState: null,
  };
  // A demo session's folder is its own project.
  const place = (cwd: string) => ({
    cwd,
    projectKey: `demo-device:${cwd}`,
    projectPath: cwd,
    projectName: cwd.split("/").pop() ?? cwd,
  });
  return [
    {
      time: "09:41",
      row: {
        ...base,
        _id: "demo1" as SessionRow["_id"],
        title: t("demo_title_1"),
        ...place("/Users/me/code/web-app"),
        status: "running",
        online: true,
        deviceName: "MacBook Pro",
        preview: t("demo_preview_1"),
        previewKind: "assistant",
        pinned: true,
        unread: 0,
      },
    },
    {
      time: "09:12",
      row: {
        ...base,
        _id: "demo2" as SessionRow["_id"],
        title: t("demo_title_2"),
        ...place("/Users/me/code/settings-ui"),
        status: "waiting",
        online: true,
        deviceName: "Mac Studio",
        preview: t("demo_preview_2"),
        previewKind: "assistant",
        pinned: false,
        unread: 2,
      },
    },
    {
      time: "08:30",
      row: {
        ...base,
        _id: "demo3" as SessionRow["_id"],
        title: t("demo_title_3"),
        ...place("/home/me/billing-service"),
        status: "idle",
        online: false,
        deviceName: "dev-box",
        preview: t("demo_preview_3"),
        previewKind: "assistant",
        pinned: false,
        unread: 0,
      },
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
  const rows = demoRows(t);
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
              <div className="flex items-center gap-2 border-b border-line px-5 py-3.5">
                <ChatsIcon size={18} className="text-accent-text" />
                <span className="text-[15px] font-semibold">{t("nav_sessions")}</span>
              </div>
              <div className="flex gap-4 border-b border-line px-5 pb-2 pt-2 text-sm">
                <span className="font-semibold text-accent-text">{t("tab_all")}</span>
                <span className="text-muted">MacBook Pro</span>
                <span className="text-muted">Mac Studio</span>
              </div>
              <ul className="p-1.5">
                {rows.map(({ row, time }) => (
                  <SessionRowView key={row._id} row={row} now={0} timeText={time} />
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
