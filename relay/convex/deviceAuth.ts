import { v } from "convex/values";
import type { Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import { fail } from "./lib/auth";
import { newSecret, newUserCode, normalizeUserCode, sha256Hex, signDeviceJwt } from "./lib/crypto";
import { deviceKind } from "./schema";
import { ensureViewer } from "./users";

/**
 * Device sign-in, the same for a computer (crok, Crok Desktop) and a phone:
 *
 * 1. The device calls `start` and shows the user code (and opens the link in a browser).
 * 2. A signed-in person approves the code on the web (`/link?code=…`), or by scanning the computer's QR in the phone app
 *    (`approve`).
 * 3. The device `poll`s with its secret device code and, once approved, receives a refresh token (kept on the device,
 *    stored here only as a hash) and its first one-hour access JWT.
 * 4. The device calls `refresh` for a new JWT before the old one runs out, and `logout` to unlink itself.
 *
 * No token ever travels in a URL: the browser only sees the short user code.
 */

const LOGIN_TTL_MS = 10 * 60 * 1000;
const POLL_INTERVAL_S = 2;
const DEVICE_SEEN_GRANULARITY_MS = 5 * 60 * 1000;

function clean(text: string, max: number): string {
  const trimmed = text.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  return trimmed.length > max ? `${trimmed.slice(0, max - 1)}…` : trimmed;
}

function webUrl(): string | null {
  const url = process.env.CROK_WEB_URL;
  return url ? url.replace(/\/+$/, "") : null;
}

export const start = mutation({
  args: {
    kind: deviceKind,
    name: v.string(),
    platform: v.string(),
    client: v.string(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const deviceCode = newSecret("crd");
    let userCode = newUserCode();
    for (let attempt = 0; attempt < 5; attempt++) {
      const clash = await ctx.db
        .query("deviceLogins")
        .withIndex("by_user_code", (q) => q.eq("userCode", userCode))
        .first();
      if (!clash) break;
      userCode = newUserCode();
    }
    await ctx.db.insert("deviceLogins", {
      deviceCodeHash: await sha256Hex(deviceCode),
      userCode,
      kind: args.kind,
      name: clean(args.name, 80) || (args.kind === "phone" ? "Phone" : "Computer"),
      platform: clean(args.platform, 80),
      client: clean(args.client, 80),
      status: "pending",
      createdAt: now,
      expiresAt: now + LOGIN_TTL_MS,
    });
    const web = webUrl();
    return {
      deviceCode,
      userCode,
      verificationUrl: web ? `${web}/link` : null,
      verificationUrlComplete: web ? `${web}/link?code=${encodeURIComponent(userCode)}` : null,
      expiresAt: now + LOGIN_TTL_MS,
      interval: POLL_INTERVAL_S,
    };
  },
});

export const poll = mutation({
  args: { deviceCode: v.string() },
  handler: async (ctx, { deviceCode }) => {
    const now = Date.now();
    const hash = await sha256Hex(deviceCode);
    const found = await ctx.db
      .query("deviceLogins")
      .withIndex("by_device_code", (q) => q.eq("deviceCodeHash", hash))
      .unique();
    if (!found || found.status === "consumed") return { status: "expired" as const };
    if (found.status === "denied") return { status: "denied" as const };
    if (found.status === "pending") {
      return now > found.expiresAt ? { status: "expired" as const } : { status: "pending" as const };
    }
    // Approved: hand out the refresh token exactly once.
    const deviceId = found.deviceId!;
    const device = await ctx.db.get(deviceId);
    if (!device || device.revokedAt !== undefined) return { status: "denied" as const };
    const refreshToken = newSecret("crr");
    await ctx.db.patch(deviceId, { refreshTokenHash: await sha256Hex(refreshToken), lastSeenAt: now });
    await ctx.db.patch(found._id, { status: "consumed" });
    const user = await ctx.db.get(device.userId);
    const access = await signDeviceJwt(deviceId, now);
    return {
      status: "approved" as const,
      deviceId,
      refreshToken,
      accessToken: access.token,
      accessTokenExpiresAt: access.expiresAt,
      user: {
        name: user?.name ?? null,
        email: user?.email ?? null,
        imageUrl: user?.imageUrl ?? null,
      },
    };
  },
});

/** A new access JWT for a linked device. Throws `REVOKED` once the device was signed out anywhere. */
export const refresh = mutation({
  args: { refreshToken: v.string() },
  handler: async (ctx, { refreshToken }) => {
    const now = Date.now();
    const hash = await sha256Hex(refreshToken);
    const linked = await ctx.db
      .query("devices")
      .withIndex("by_refresh", (q) => q.eq("refreshTokenHash", hash))
      .unique();
    if (!linked || linked.revokedAt !== undefined) fail("REVOKED", "This device was signed out.");
    if (now - linked.lastSeenAt > DEVICE_SEEN_GRANULARITY_MS) {
      await ctx.db.patch(linked._id, { lastSeenAt: now });
    }
    const access = await signDeviceJwt(linked._id, now);
    return { deviceId: linked._id, accessToken: access.token, accessTokenExpiresAt: access.expiresAt };
  },
});

/** Unlinks the calling device (by its refresh token, so it works with an expired JWT too). */
export const logout = mutation({
  args: { refreshToken: v.string() },
  handler: async (ctx, { refreshToken }) => {
    const hash = await sha256Hex(refreshToken);
    const device = await ctx.db
      .query("devices")
      .withIndex("by_refresh", (q) => q.eq("refreshTokenHash", hash))
      .unique();
    if (!device || device.revokedAt !== undefined) return null;
    await revokeDevice(ctx, device._id);
    return null;
  },
});

/** What the approval page shows before the person confirms: which device is asking, and from where. */
export const pendingLogin = query({
  args: { userCode: v.string() },
  handler: async (ctx, { userCode }) => {
    // Any signed-in caller: a person who just signed in with Clerk may not be stored yet (`users.ensure`).
    if (!(await ctx.auth.getUserIdentity())) fail("UNAUTHENTICATED", "Sign in first.");
    const login = await ctx.db
      .query("deviceLogins")
      .withIndex("by_user_code", (q) => q.eq("userCode", normalizeUserCode(userCode)))
      .first();
    if (!login) return null;
    const expired = login.status === "pending" && Date.now() > login.expiresAt;
    return {
      userCode: login.userCode,
      kind: login.kind,
      name: login.name,
      platform: login.platform,
      client: login.client,
      createdAt: login.createdAt,
      expiresAt: login.expiresAt,
      status: expired ? ("expired" as const) : login.status,
    };
  },
});

export const approve = mutation({
  args: { userCode: v.string() },
  handler: async (ctx, { userCode }) => {
    const viewer = await ensureViewer(ctx);
    const now = Date.now();
    const login = await ctx.db
      .query("deviceLogins")
      .withIndex("by_user_code", (q) => q.eq("userCode", normalizeUserCode(userCode)))
      .first();
    if (!login) fail("NOT_FOUND", "That code is not valid. Check it and try again.");
    if (login.status !== "pending") fail("INVALID", "That code was already used.");
    if (now > login.expiresAt) fail("EXPIRED", "That code has expired. Start the sign-in again on the device.");
    const deviceId = await ctx.db.insert("devices", {
      userId: viewer.user._id,
      kind: login.kind,
      name: login.name,
      platform: login.platform,
      client: login.client,
      refreshTokenHash: "",
      createdAt: now,
      lastSeenAt: now,
      online: false,
    });
    await ctx.db.patch(login._id, { status: "approved", userId: viewer.user._id, deviceId });
    return { deviceId, kind: login.kind, name: login.name };
  },
});

export const deny = mutation({
  args: { userCode: v.string() },
  handler: async (ctx, { userCode }) => {
    if (!(await ctx.auth.getUserIdentity())) fail("UNAUTHENTICATED", "Sign in first.");
    const login = await ctx.db
      .query("deviceLogins")
      .withIndex("by_user_code", (q) => q.eq("userCode", normalizeUserCode(userCode)))
      .first();
    if (login && login.status === "pending") await ctx.db.patch(login._id, { status: "denied" });
    return null;
  },
});

/** Signs a device out: its refresh token stops working, its sessions go offline, its queued commands fail. */
export async function revokeDevice(ctx: MutationCtx, deviceId: Id<"devices">): Promise<void> {
  const now = Date.now();
  await ctx.db.patch(deviceId, { revokedAt: now, online: false, refreshTokenHash: "" });
  const hosts = await ctx.db
    .query("hosts")
    .withIndex("by_device", (q) => q.eq("deviceId", deviceId))
    .collect();
  for (const host of hosts) {
    if (host.online) await ctx.db.patch(host._id, { online: false });
  }
  const sessions = await ctx.db
    .query("sessions")
    .withIndex("by_device", (q) => q.eq("deviceId", deviceId))
    .collect();
  for (const session of sessions) {
    if (session.online) await ctx.db.patch(session._id, { online: false, status: "idle" });
  }
  for (const status of ["pending", "delivered"] as const) {
    const commands = await ctx.db
      .query("commands")
      .withIndex("by_device_status", (q) => q.eq("deviceId", deviceId).eq("status", status))
      .collect();
    for (const command of commands) {
      await ctx.db.patch(command._id, { status: "failed", error: "The computer was signed out.", updatedAt: now });
    }
  }
}
