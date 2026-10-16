import { ConvexError } from "convex/values";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { deviceIssuer } from "./crypto";

/** Error codes clients branch on. Every error thrown to a client is `ConvexError<{ code, message }>`. */
export type ErrorCode =
  | "UNAUTHENTICATED"
  | "REVOKED"
  | "FORBIDDEN"
  | "NOT_FOUND"
  | "OFFLINE"
  | "INVALID"
  | "EXPIRED"
  | "NOT_CONFIGURED";

export function fail(code: ErrorCode, message: string): never {
  throw new ConvexError({ code, message });
}

export type Viewer = {
  user: Doc<"users">;
  /** The calling device, or undefined for a person on the web app. */
  device?: Doc<"devices">;
};

function isDeviceIdentity(issuer: string): boolean {
  try {
    return issuer.replace(/\/+$/, "") === deviceIssuer();
  } catch {
    return false;
  }
}

/** The caller, or null when nobody is signed in or a web user has not been stored yet (`users.ensure`). */
export async function getViewer(ctx: QueryCtx | MutationCtx): Promise<Viewer | null> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) return null;
  if (isDeviceIdentity(identity.issuer)) {
    const deviceId = ctx.db.normalizeId("devices", identity.subject);
    if (!deviceId) return null;
    const device = await ctx.db.get(deviceId);
    if (!device || device.revokedAt !== undefined) fail("REVOKED", "This device was signed out.");
    const user = await ctx.db.get(device.userId);
    if (!user) fail("REVOKED", "This account no longer exists.");
    return { user, device };
  }
  const user = await ctx.db
    .query("users")
    .withIndex("by_token", (q) => q.eq("tokenIdentifier", identity.tokenIdentifier))
    .unique();
  return user ? { user } : null;
}

export async function requireViewer(ctx: QueryCtx | MutationCtx): Promise<Viewer> {
  const viewer = await getViewer(ctx);
  if (!viewer) fail("UNAUTHENTICATED", "Sign in first.");
  return viewer;
}

/** A linked computer acting for one of its hosts (a crok process). */
export async function requireHost(
  ctx: QueryCtx | MutationCtx,
  hostId: Id<"hosts">,
): Promise<{ viewer: Viewer & { device: Doc<"devices"> }; host: Doc<"hosts"> }> {
  const viewer = await requireViewer(ctx);
  const device = viewer.device;
  if (!device || device.kind !== "computer") fail("FORBIDDEN", "Only a linked computer can do this.");
  const host = await ctx.db.get(hostId);
  if (!host || host.deviceId !== device._id) fail("NOT_FOUND", "Unknown host.");
  return { viewer: { ...viewer, device }, host };
}

/**
 * A session the caller owns. Viewer functions take the id as a plain string (it comes from URLs and phones), so a
 * malformed one is a clean `NOT_FOUND` rather than a validation error the production deployment would redact.
 */
export async function requireSession(
  ctx: QueryCtx | MutationCtx,
  viewer: Viewer,
  sessionDocId: string,
): Promise<Doc<"sessions">> {
  const id = ctx.db.normalizeId("sessions", sessionDocId);
  const session = id ? await ctx.db.get(id) : null;
  if (!session || session.userId !== viewer.user._id) fail("NOT_FOUND", "No such session.");
  return session;
}

/** A command the caller sent, by its id as a plain string; null when there is none. */
export async function ownCommand(
  ctx: QueryCtx | MutationCtx,
  viewer: Viewer,
  commandId: string,
): Promise<Doc<"commands"> | null> {
  const id = ctx.db.normalizeId("commands", commandId);
  const command = id ? await ctx.db.get(id) : null;
  return command && command.userId === viewer.user._id ? command : null;
}

/** How a command's sender is shown on the computer and in the transcript. */
export function viewerLabel(viewer: Viewer): string {
  return viewer.device ? viewer.device.name : "Web";
}
