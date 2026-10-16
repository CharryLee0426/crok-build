import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { revokeDevice } from "./deviceAuth";
import { fail, requireViewer } from "./lib/auth";

/**
 * The account's linked computers and phones, for the "Devices" screen (Telegram's Active Sessions): this device first,
 * then online computers, then the rest by last activity.
 */
export const list = query({
  args: {},
  handler: async (ctx) => {
    const viewer = await requireViewer(ctx);
    const devices = await ctx.db
      .query("devices")
      .withIndex("by_user", (q) => q.eq("userId", viewer.user._id))
      .collect();
    const live = devices.filter((d) => d.revokedAt === undefined);
    const rows = await Promise.all(
      live.map(async (device) => {
        const sessions = await ctx.db
          .query("sessions")
          .withIndex("by_device", (q) => q.eq("deviceId", device._id))
          .collect();
        return {
          _id: device._id,
          kind: device.kind,
          name: device.name,
          platform: device.platform,
          client: device.client,
          createdAt: device.createdAt,
          lastSeenAt: device.lastSeenAt,
          online: device.online,
          isCurrent: viewer.device?._id === device._id,
          liveSessionCount: sessions.filter((s) => s.online && !s.archived).length,
        };
      }),
    );
    rows.sort((a, b) => {
      if (a.isCurrent !== b.isCurrent) return a.isCurrent ? -1 : 1;
      if (a.online !== b.online) return a.online ? -1 : 1;
      return b.lastSeenAt - a.lastSeenAt;
    });
    return rows;
  },
});

export const rename = mutation({
  args: { deviceId: v.id("devices"), name: v.string() },
  handler: async (ctx, { deviceId, name }) => {
    const viewer = await requireViewer(ctx);
    const device = await ctx.db.get(deviceId);
    if (!device || device.userId !== viewer.user._id || device.revokedAt !== undefined) {
      fail("NOT_FOUND", "No such device.");
    }
    const trimmed = name.trim().slice(0, 80);
    if (!trimmed) fail("INVALID", "A name is required.");
    await ctx.db.patch(deviceId, { name: trimmed });
    return null;
  },
});

/** Signs a device out everywhere. A device may also remove itself. */
export const revoke = mutation({
  args: { deviceId: v.id("devices") },
  handler: async (ctx, { deviceId }) => {
    const viewer = await requireViewer(ctx);
    const device = await ctx.db.get(deviceId);
    if (!device || device.userId !== viewer.user._id) fail("NOT_FOUND", "No such device.");
    if (device.revokedAt === undefined) await revokeDevice(ctx, deviceId);
    return null;
  },
});

/** "Sign out all other devices". */
export const revokeOthers = mutation({
  args: {},
  handler: async (ctx) => {
    const viewer = await requireViewer(ctx);
    const devices = await ctx.db
      .query("devices")
      .withIndex("by_user", (q) => q.eq("userId", viewer.user._id))
      .collect();
    let count = 0;
    for (const device of devices) {
      if (device.revokedAt !== undefined || device._id === viewer.device?._id) continue;
      await revokeDevice(ctx, device._id);
      count++;
    }
    return { count };
  },
});
