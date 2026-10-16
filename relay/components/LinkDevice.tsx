"use client";

import { useMutation, useQuery } from "convex/react";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { api } from "@/convex/_generated/api";
import { normalizeUserCode } from "@/lib/browser";
import { relayError } from "@/lib/errors";
import { formatCountdown, formatRelative } from "@/lib/format";
import type { PendingLogin } from "@/lib/types";
import { useI18n } from "./I18nProvider";
import { CheckIcon, ClockIcon, ComputerIcon, LinkIcon, PhoneIcon, WarningIcon, XIcon } from "./icons";
import { useErrorText } from "./SessionList";
import { useToast } from "./Toast";
import { Button, ButtonLink, Code, Loading, useNow } from "./ui";

export const APP_RETURN_URL = "crok://signed-in";

export type LinkOutcome =
  | { kind: "approved"; name: string }
  | { kind: "denied"; name: string }
  | { kind: "expired" }
  | { kind: "used" }
  | { kind: "notFound" };

function linkHref(code: string, app: boolean) {
  return `/link?code=${encodeURIComponent(code)}${app ? "&app=1" : ""}`;
}

/** `/link`: type the code a device shows. */
export function LinkEntry({ app = false }: { app?: boolean }) {
  const { t, tx } = useI18n();
  const router = useRouter();
  const [code, setCode] = useState("");
  const [invalid, setInvalid] = useState(false);
  return (
    <div className="mx-auto w-full max-w-md px-4 py-12 sm:py-16">
      <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-accent-soft text-accent-text">
        <LinkIcon size={26} />
      </div>
      <h1 className="mt-5 text-center text-2xl font-semibold tracking-tight">{t("link_title")}</h1>
      <p className="mt-2 text-center text-sm leading-relaxed text-muted">{t("link_lead")}</p>
      <form
        className="mt-8"
        onSubmit={(e) => {
          e.preventDefault();
          const normalized = normalizeUserCode(code);
          if (normalized.replace("-", "").length !== 8) {
            setInvalid(true);
            return;
          }
          router.push(linkHref(normalized, app));
        }}
      >
        <label htmlFor="link-code" className="block text-xs font-semibold uppercase tracking-wide text-faint">
          {t("link_code_label")}
        </label>
        <input
          id="link-code"
          value={code}
          onChange={(e) => {
            setCode(normalizeUserCode(e.target.value));
            setInvalid(false);
          }}
          autoFocus
          autoComplete="one-time-code"
          autoCapitalize="characters"
          spellCheck={false}
          inputMode="text"
          placeholder="BCDF-GHJK"
          aria-invalid={invalid}
          aria-describedby={invalid ? "link-code-error" : undefined}
          className="mt-2 h-14 w-full rounded-2xl border border-line bg-surface text-center font-mono text-2xl tracking-[0.25em] text-fg placeholder:text-faint/60 focus:border-accent focus:outline-none"
        />
        {invalid ? (
          <p id="link-code-error" className="mt-2 text-center text-[13px] text-danger">
            {t("link_code_invalid")}
          </p>
        ) : null}
        <Button type="submit" tone="primary" size="lg" className="mt-5 w-full">
          {t("link_continue")}
        </Button>
      </form>
      <p className="mt-8 text-center text-[13px] leading-relaxed text-muted">
        {tx("devices_link_hint", { cmd: <Code>crok remote login</Code> })}
      </p>
    </div>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4 py-2">
      <dt className="shrink-0 text-[13px] text-muted">{label}</dt>
      <dd className="min-w-0 break-words text-right text-[14px] text-fg">{children}</dd>
    </div>
  );
}

function ResultScreen({
  tone,
  title,
  children,
  actions,
}: {
  tone: "ok" | "bad" | "neutral";
  title: string;
  children: ReactNode;
  actions?: ReactNode;
}) {
  const icon = tone === "ok" ? <CheckIcon size={30} /> : tone === "bad" ? <XIcon size={30} /> : <ClockIcon size={30} />;
  const color =
    tone === "ok" ? "bg-accent-soft text-accent-text" : tone === "bad" ? "bg-danger-soft text-danger" : "bg-surface-2 text-muted";
  return (
    <div className="mx-auto w-full max-w-md px-4 py-14 text-center sm:py-20">
      <div className={`mx-auto flex h-16 w-16 items-center justify-center rounded-full ${color}`}>{icon}</div>
      <h1 className="mt-5 text-2xl font-semibold tracking-tight">{title}</h1>
      <p className="mt-2 text-[15px] leading-relaxed text-muted">{children}</p>
      {actions ? <div className="mt-8 flex flex-wrap justify-center gap-2">{actions}</div> : null}
    </div>
  );
}

/** The approval page: which device asks (name, kind, platform, app, when), a warning, Approve / Deny, the outcome. */
export function LinkApprovalView({
  code,
  login,
  outcome,
  busy,
  app,
  now,
  onApprove,
  onDeny,
}: {
  code: string;
  login: PendingLogin | null | undefined;
  outcome: LinkOutcome | null;
  busy: "approve" | "deny" | null;
  app: boolean;
  now: number;
  onApprove: () => void;
  onDeny: () => void;
}) {
  const { t, lang } = useI18n();
  const returnLink = app ? (
    <a href={APP_RETURN_URL} className="inline-flex h-10 items-center rounded-full bg-accent px-5 text-sm font-medium text-accent-fg hover:bg-accent-hover">
      {t("link_return_app")}
    </a>
  ) : null;
  const another = (
    <ButtonLink href={app ? "/link?app=1" : "/link"} tone="secondary">
      {t("link_try_another")}
    </ButtonLink>
  );

  let result: LinkOutcome | null = outcome;
  if (!result && login === null) result = { kind: "notFound" };
  if (!result && login) {
    if (login.status === "expired" || (login.status === "pending" && now > login.expiresAt)) result = { kind: "expired" };
    else if (login.status === "denied") result = { kind: "denied", name: login.name };
    else if (login.status === "approved" || login.status === "consumed") result = { kind: "used" };
  }

  if (result) {
    switch (result.kind) {
      case "approved":
        return (
          <ResultScreen tone="ok" title={t("link_approved_title")} actions={returnLink}>
            {app ? t("link_approved_app", { name: result.name }) : t("link_approved", { name: result.name })}
          </ResultScreen>
        );
      case "denied":
        return (
          <ResultScreen tone="bad" title={t("link_denied_title")} actions={returnLink}>
            {t("link_denied", { name: result.name })}
          </ResultScreen>
        );
      case "expired":
        return (
          <ResultScreen tone="neutral" title={t("link_expired_title")} actions={returnLink ?? another}>
            {t("link_expired")}
          </ResultScreen>
        );
      case "used":
        return (
          <ResultScreen
            tone="neutral"
            title={t("link_used_title")}
            actions={
              <ButtonLink href="/devices" tone="secondary">
                {t("link_open_devices")}
              </ButtonLink>
            }
          >
            {t("link_used")}
          </ResultScreen>
        );
      case "notFound":
        return (
          <ResultScreen tone="bad" title={t("link_not_found_title")} actions={another}>
            {t("link_not_found", { code })}
          </ResultScreen>
        );
    }
  }

  if (!login) return <Loading />;

  const remaining = login.expiresAt - now;
  return (
    <div className="mx-auto w-full max-w-md px-4 py-10 sm:py-14">
      <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-2xl bg-accent-soft text-accent-text">
        {login.kind === "phone" ? <PhoneIcon size={30} /> : <ComputerIcon size={30} />}
      </div>
      <h1 className="mt-5 text-center text-2xl font-semibold tracking-tight">{t("link_request_title")}</h1>
      <p className="mt-2 text-center text-sm text-muted">{t("link_request_lead")}</p>

      <div className="mt-6 rounded-2xl border border-line bg-surface px-4 pb-2 pt-4 shadow-card">
        <div className="text-center text-lg font-semibold">{login.name}</div>
        <dl className="mt-3 divide-y divide-line border-t border-line">
          <Field label={t("link_field_kind")}>{login.kind === "phone" ? t("kind_phone") : t("kind_computer")}</Field>
          {login.platform ? <Field label={t("link_field_platform")}>{login.platform}</Field> : null}
          {login.client ? <Field label={t("link_field_app")}>{login.client}</Field> : null}
          <Field label={t("link_field_code")}>
            <span className="font-mono tracking-wider">{login.userCode}</span>
          </Field>
        </dl>
      </div>
      <p className="mt-3 flex flex-wrap justify-center gap-x-3 gap-y-1 text-center text-[13px] text-muted">
        <span>{t("link_asked", { time: formatRelative(login.createdAt, lang, now) })}</span>
        <span aria-hidden="true">·</span>
        <span className={remaining < 60_000 ? "text-warning" : ""}>
          {t("link_expires_in", { time: formatCountdown(remaining) })}
        </span>
      </p>

      <div className="mt-6 flex items-start gap-2.5 rounded-xl bg-warning-soft px-4 py-3 text-[13.5px] leading-relaxed text-warning">
        <WarningIcon size={18} className="mt-0.5 shrink-0" />
        <span>{t("link_warning")}</span>
      </div>

      <div className="mt-6 grid grid-cols-2 gap-3">
        <Button size="lg" tone="secondary" onClick={onDeny} busy={busy === "deny"} disabled={busy !== null}>
          {t("deny")}
        </Button>
        <Button size="lg" tone="primary" onClick={onApprove} busy={busy === "approve"} disabled={busy !== null}>
          {t("approve")}
        </Button>
      </div>
    </div>
  );
}

/** `/link?code=…` live: `deviceAuth:pendingLogin`, then `approve` / `deny`. */
export function LinkApproval({ code, app }: { code: string; app: boolean }) {
  const toast = useToast();
  const errorText = useErrorText();
  const now = useNow(1000);
  const login = useQuery(api.deviceAuth.pendingLogin, { userCode: code });
  const approve = useMutation(api.deviceAuth.approve);
  const deny = useMutation(api.deviceAuth.deny);
  const [outcome, setOutcome] = useState<LinkOutcome | null>(null);
  const [busy, setBusy] = useState<"approve" | "deny" | null>(null);

  // A phone that opened this page in its browser sheet gets control back at once.
  useEffect(() => {
    if (app && outcome?.kind === "approved") window.location.href = APP_RETURN_URL;
  }, [app, outcome]);

  return (
    <LinkApprovalView
      code={code}
      login={login}
      outcome={outcome}
      busy={busy}
      app={app}
      now={now}
      onApprove={() => {
        setBusy("approve");
        approve({ userCode: code }).then(
          (result) => setOutcome({ kind: "approved", name: result.name }),
          (error) => {
            const { code: errorCode } = relayError(error);
            if (errorCode === "NOT_FOUND") setOutcome({ kind: "notFound" });
            else if (errorCode === "INVALID") setOutcome({ kind: "used" });
            else if (errorCode === "EXPIRED") setOutcome({ kind: "expired" });
            else toast.show(errorText(error), "error");
            setBusy(null);
          },
        );
      }}
      onDeny={() => {
        setBusy("deny");
        const name = login?.name ?? "";
        deny({ userCode: code }).then(
          () => setOutcome({ kind: "denied", name }),
          (error) => {
            toast.show(errorText(error), "error");
            setBusy(null);
          },
        );
      }}
    />
  );
}
