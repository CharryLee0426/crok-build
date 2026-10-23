"use client";

import { useMutation, useQuery } from "convex/react";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import { api } from "@/convex/_generated/api";
import { describeBrowser } from "@/lib/browser";
import { formatRelative } from "@/lib/format";
import type { DeviceRow } from "@/lib/types";
import { useI18n } from "./I18nProvider";
import { ComputerIcon, GlobeIcon, LinkIcon, PencilIcon, PhoneIcon } from "./icons";
import { useErrorText } from "./SessionList";
import { useToast } from "./Toast";
import { Button, ButtonLink, Code, ConfirmDialog, IconButton, Loading, useNow } from "./ui";

type DeviceId = DeviceRow["_id"];

export type DevicesActions = {
  rename: (id: DeviceId, name: string) => Promise<void>;
  revoke: (id: DeviceId) => Promise<void>;
  revokeOthers: () => Promise<number>;
};

function DeviceIcon({ kind }: { kind: "computer" | "phone" | "browser" }) {
  const icon =
    kind === "computer" ? <ComputerIcon size={20} /> : kind === "phone" ? <PhoneIcon size={20} /> : <GlobeIcon size={20} />;
  return (
    <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent-text">
      {icon}
    </span>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mt-6">
      <h2 className="mb-2 px-1 text-xs font-semibold uppercase tracking-wide text-faint">{title}</h2>
      <ul className="divide-y divide-line overflow-hidden rounded-2xl border border-line bg-surface">{children}</ul>
    </section>
  );
}

function DeviceItem({
  device,
  now,
  actions,
  onSignOut,
}: {
  device: DeviceRow;
  now: number;
  actions: DevicesActions;
  onSignOut: (device: DeviceRow) => void;
}) {
  const { t, tn, lang } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(device.name);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!editing) setName(device.name);
  }, [device.name, editing]);

  const save = async () => {
    const trimmed = name.trim();
    if (!trimmed || trimmed === device.name) {
      setEditing(false);
      return;
    }
    setSaving(true);
    try {
      await actions.rename(device._id, trimmed);
      setEditing(false);
    } catch (error) {
      toast.show(errorText(error), "error");
    } finally {
      setSaving(false);
    }
  };

  return (
    <li className="flex items-center gap-3 px-4 py-3">
      <DeviceIcon kind={device.kind} />
      <div className="min-w-0 flex-1">
        {editing ? (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void save();
            }}
            className="flex flex-wrap items-center gap-2"
          >
            <input
              autoFocus
              value={name}
              maxLength={80}
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Escape") setEditing(false);
              }}
              aria-label={t("device_name")}
              className="h-9 min-w-0 flex-1 rounded-lg border border-line bg-canvas px-3 text-[15px] focus:border-accent focus:outline-none"
            />
            <Button type="submit" size="sm" tone="primary" busy={saving}>
              {t("save")}
            </Button>
            <Button size="sm" tone="ghost" onClick={() => setEditing(false)}>
              {t("cancel")}
            </Button>
          </form>
        ) : (
          <div className="flex items-center gap-1">
            <span className="truncate text-[15px] font-medium">{device.name}</span>
            <IconButton label={t("rename")} className="h-7 w-7" onClick={() => setEditing(true)}>
              <PencilIcon size={14} />
            </IconButton>
          </div>
        )}
        <div className="truncate text-[13px] text-muted">
          {[device.platform, device.client].filter(Boolean).join(" · ")}
        </div>
        <div className="mt-0.5 text-[13px]">
          {device.online ? (
            <span className="font-medium text-accent-text">{t("device_online")}</span>
          ) : (
            <span className="text-faint">{t("last_seen", { time: formatRelative(device.lastSeenAt, lang, now) })}</span>
          )}
          {device.kind === "computer" && device.liveSessionCount > 0 ? (
            <span className="text-muted"> · {tn("live_sessions", device.liveSessionCount)}</span>
          ) : null}
        </div>
      </div>
      {!editing ? (
        <Button size="sm" tone="dangerGhost" className="shrink-0" onClick={() => onSignOut(device)}>
          {t("sign_out")}
        </Button>
      ) : null}
    </li>
  );
}

/** Telegram's Active Sessions: this browser, computers, phones; rename, sign out one, sign out all others. */
export function DevicesView({
  devices,
  browserLabel,
  now,
  actions,
  compact = false,
}: {
  devices: DeviceRow[] | undefined;
  browserLabel: string;
  now: number;
  actions: DevicesActions;
  /** Profile › Devices in the left column: no page title, no footer under "Sign out all other devices". */
  compact?: boolean;
}) {
  const { t, tn, tx } = useI18n();
  const toast = useToast();
  const errorText = useErrorText();
  const [confirm, setConfirm] = useState<DeviceRow | "all" | null>(null);
  const [busy, setBusy] = useState(false);

  // A person on the web is no device of their own ("This browser"); a linked device viewing this (the phone apps'
  // web views, the dev harness) is `isCurrent` and shows as "This device" instead.
  const current = (devices ?? []).find((d) => d.isCurrent);
  const others = (devices ?? []).filter((d) => !d.isCurrent);
  const computers = others.filter((d) => d.kind === "computer");
  const phones = others.filter((d) => d.kind === "phone");

  const runConfirm = async () => {
    if (!confirm) return;
    setBusy(true);
    try {
      if (confirm === "all") {
        const count = await actions.revokeOthers();
        toast.show(tn("signed_out", count));
      } else {
        await actions.revoke(confirm._id);
        toast.show(t("signed_out_device", { name: confirm.name }));
      }
      setConfirm(null);
    } catch (error) {
      toast.show(errorText(error), "error");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={compact ? "w-full pb-4" : "mx-auto w-full max-w-2xl px-4 py-8 sm:px-6"}>
      {compact ? (
        <p className="mt-4 px-1 text-[13px] leading-relaxed text-muted">{t("devices_lead")}</p>
      ) : (
        <>
          <h1 className="text-2xl font-semibold tracking-tight">{t("devices_title")}</h1>
          <p className="mt-1 text-sm text-muted">{t("devices_lead")}</p>
        </>
      )}

      <Section title={t("this_device")}>
        {current ? (
          <DeviceItem device={{ ...current, online: true }} now={now} actions={actions} onSignOut={setConfirm} />
        ) : (
          <li className="flex items-center gap-3 px-4 py-3">
            <DeviceIcon kind="browser" />
            <div className="min-w-0 flex-1">
              <div className="text-[15px] font-medium">{t("this_browser")}</div>
              <div className="truncate text-[13px] text-muted">{browserLabel}</div>
              <div className="mt-0.5 text-[13px] font-medium text-accent-text">{t("device_online")}</div>
            </div>
          </li>
        )}
      </Section>

      {devices === undefined ? (
        <Loading />
      ) : others.length === 0 ? (
        <p className="mt-8 rounded-2xl border border-dashed border-line-strong px-6 py-8 text-center text-sm text-muted">
          {t("devices_empty")}
        </p>
      ) : (
        <>
          {computers.length ? (
            <Section title={t("computers")}>
              {computers.map((d) => (
                <DeviceItem key={d._id} device={d} now={now} actions={actions} onSignOut={setConfirm} />
              ))}
            </Section>
          ) : null}
          {phones.length ? (
            <Section title={t("phones")}>
              {phones.map((d) => (
                <DeviceItem key={d._id} device={d} now={now} actions={actions} onSignOut={setConfirm} />
              ))}
            </Section>
          ) : null}
          <div className="mt-6">
            <Button tone="danger" className={compact ? "w-full" : "w-full sm:w-auto"} onClick={() => setConfirm("all")}>
              {t("sign_out_all")}
            </Button>
          </div>
        </>
      )}

      {compact ? null : (
        <div className="mt-10 flex flex-col gap-3 rounded-2xl bg-surface-2 px-5 py-4 text-sm text-muted sm:flex-row sm:items-center">
          <p className="flex-1 leading-relaxed">{tx("devices_link_hint", { cmd: <Code>crok remote login</Code> })}</p>
          <ButtonLink href="/link" size="sm" className="shrink-0">
            <LinkIcon size={15} />
            {t("nav_link")}
          </ButtonLink>
        </div>
      )}

      <ConfirmDialog
        open={confirm !== null}
        title={confirm === "all" ? t("sign_out_all_title") : confirm ? t("sign_out_device_title", { name: confirm.name }) : ""}
        body={confirm === "all" ? t("sign_out_all_body") : t("sign_out_device_body")}
        confirmLabel={t("sign_out")}
        cancelLabel={t("cancel")}
        busy={busy}
        onConfirm={() => void runConfirm()}
        onCancel={() => setConfirm(null)}
      />
    </div>
  );
}

export function DevicesScreen() {
  const devices = useQuery(api.devices.list);
  const rename = useMutation(api.devices.rename);
  const revoke = useMutation(api.devices.revoke);
  const revokeOthers = useMutation(api.devices.revokeOthers);
  const now = useNow(30_000);
  const [browserLabel, setBrowserLabel] = useState("");
  useEffect(() => setBrowserLabel(describeBrowser(navigator.userAgent)), []);
  return (
    <DevicesView
      devices={devices}
      browserLabel={browserLabel}
      now={now}
      actions={{
        rename: async (deviceId, name) => {
          await rename({ deviceId, name });
        },
        revoke: async (deviceId) => {
          await revoke({ deviceId });
        },
        revokeOthers: async () => (await revokeOthers({})).count,
      }}
    />
  );
}
