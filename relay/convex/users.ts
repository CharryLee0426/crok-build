import type { MutationCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import type { Viewer } from "./lib/auth";
import { fail, getViewer } from "./lib/auth";

/**
 * Stores the signed-in web user (Clerk identity) the first time, and refreshes name, email and picture after that.
 * A device caller is already tied to a user and is returned as is.
 */
export async function ensureViewer(ctx: MutationCtx): Promise<Viewer> {
  const existing = await getViewer(ctx);
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) fail("UNAUTHENTICATED", "Sign in first.");
  if (existing?.device) return existing;
  const profile = {
    name: identity.name ?? identity.nickname ?? identity.preferredUsername ?? undefined,
    email: identity.email ?? undefined,
    imageUrl: identity.pictureUrl ?? undefined,
  };
  if (existing) {
    const { user } = existing;
    if (user.name !== profile.name || user.email !== profile.email || user.imageUrl !== profile.imageUrl) {
      await ctx.db.patch(user._id, profile);
      return { user: { ...user, ...profile } };
    }
    return existing;
  }
  const userId = await ctx.db.insert("users", {
    tokenIdentifier: identity.tokenIdentifier,
    ...profile,
    createdAt: Date.now(),
  });
  const user = await ctx.db.get(userId);
  return { user: user! };
}

/** Called by the web app after Clerk sign-in. */
export const ensure = mutation({
  args: {},
  handler: async (ctx) => {
    const { user } = await ensureViewer(ctx);
    return { userId: user._id, name: user.name ?? null, email: user.email ?? null, imageUrl: user.imageUrl ?? null };
  },
});

/** The signed-in account and, for a device caller, the device itself. Null when signed out. */
export const me = query({
  args: {},
  handler: async (ctx) => {
    const viewer = await getViewer(ctx);
    if (!viewer) return null;
    const { user, device } = viewer;
    return {
      userId: user._id,
      name: user.name ?? null,
      email: user.email ?? null,
      imageUrl: user.imageUrl ?? null,
      device: device
        ? { deviceId: device._id, kind: device.kind, name: device.name, platform: device.platform, client: device.client }
        : null,
    };
  },
});
