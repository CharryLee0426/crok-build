import type { Infer } from "convex/values";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import { internalMutation, mutation, query } from "./_generated/server";
import { fail, requireViewer } from "./lib/auth";
import type { attachmentInput } from "./schema";
import { attachment } from "./schema";

/**
 * Photos and files sent with prompts (relay/DESIGN.md §2, "Photos and files"). A client uploads each file straight to
 * the relay's file storage (`uploadUrl`, then `POST` the bytes), then names the uploads in `commands:sendPrompt` or
 * `sessions:create`, which claim them for the session. The computer downloads them from the URLs in its inbox; every
 * viewer reads them from the URLs on the transcript item.
 */

export type Attachment = Infer<typeof attachment>;
export type AttachmentInput = Infer<typeof attachmentInput>;
export type AttachmentWithUrls = Attachment & { url: string | null; thumbUrl: string | null };

export const MAX_ATTACHMENTS = 10;
export const MAX_FILE_BYTES = 20 * 1024 * 1024;
const MAX_THUMB_BYTES = 512 * 1024;
/** What models read as images; any other type is sent to the computer as a file. */
const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
const NAME_MAX = 200;
const DIMENSION_MAX = 100_000;
/** An upload no prompt claimed in this long is deleted. */
const UNCLAIMED_KEEP_MS = 24 * 60 * 60 * 1000;
const SWEEP_BATCH = 200;
const DELETE_BATCH = 200;

/** A fresh upload URL (valid for an hour): `POST` the file's bytes there with its `Content-Type`; the answer is `{storageId}`. */
export const uploadUrl = mutation({
  args: {},
  handler: async (ctx) => {
    await requireViewer(ctx);
    return { url: await ctx.storage.generateUploadUrl() };
  },
});

/** `image/jpeg` for `IMAGE/JPG; charset=…`; `application/octet-stream` when the upload named no type. */
export function normalizeMime(contentType: string | undefined): string {
  const bare = (contentType ?? "").split(";", 1)[0]?.trim().toLowerCase() ?? "";
  if (bare === "image/jpg" || bare === "image/pjpeg") return "image/jpeg";
  return /^[a-z0-9.+-]+\/[a-z0-9.+-]+$/.test(bare) ? bare : "application/octet-stream";
}

/** A file name without folders or control characters, at most 200 characters, never empty. */
export function cleanName(name: string): string {
  const base = name.split(/[\\/]/).pop() ?? "";
  // eslint-disable-next-line no-control-regex
  const clean = base.replace(/[\u0000-\u001f\u007f]/g, "").trim();
  if (!clean || clean === "." || clean === "..") return "file";
  return clean.length > NAME_MAX ? clean.slice(clean.length - NAME_MAX) : clean;
}

function dimension(value: number | undefined): number | undefined {
  if (value === undefined || !Number.isFinite(value) || value <= 0) return undefined;
  return Math.min(DIMENSION_MAX, Math.round(value));
}

/**
 * Claims one upload for the session: it must exist, fit `maxBytes`, and not belong to anyone else. The first claim
 * records it in `files` (with the session it goes with); later claims by the same person are fine (a retried prompt).
 */
async function claimStorage(
  ctx: MutationCtx,
  userId: Id<"users">,
  sessionDocId: Id<"sessions">,
  raw: string,
  maxBytes: number,
): Promise<{ _id: Id<"_storage">; size: number; contentType?: string }> {
  const id = ctx.db.system.normalizeId("_storage", raw);
  const stored = id ? await ctx.db.system.get(id) : null;
  if (!id || !stored) fail("INVALID", "An attachment is no longer on the relay. Attach it again.");
  if (stored.size > maxBytes) {
    fail("INVALID", `Files are limited to ${Math.round(maxBytes / (1024 * 1024))} MB.`);
  }
  const claimed = await ctx.db
    .query("files")
    .withIndex("by_storage", (q) => q.eq("storageId", id))
    .unique();
  if (claimed && claimed.userId !== userId) fail("FORBIDDEN", "That upload belongs to someone else.");
  if (!claimed) {
    await ctx.db.insert("files", {
      userId,
      storageId: id,
      sessionDocId,
      sha256: stored.sha256,
      size: stored.size,
      contentType: stored.contentType,
      createdAt: Date.now(),
    });
  }
  return stored;
}

/** The photos and files a viewer sends with a prompt, checked and claimed for the session, in order. */
export async function claimAttachments(
  ctx: MutationCtx,
  userId: Id<"users">,
  sessionDocId: Id<"sessions">,
  inputs: AttachmentInput[],
): Promise<Attachment[]> {
  if (inputs.length > MAX_ATTACHMENTS) fail("INVALID", `At most ${MAX_ATTACHMENTS} photos and files per message.`);
  const claimed: Attachment[] = [];
  for (const input of inputs) {
    const stored = await claimStorage(ctx, userId, sessionDocId, input.storageId, MAX_FILE_BYTES);
    const mimeType = normalizeMime(stored.contentType);
    const kind = IMAGE_TYPES.has(mimeType) ? "image" : "file";
    let thumbId: Id<"_storage"> | undefined;
    if (kind === "image" && input.thumbId) {
      const thumb = await claimStorage(ctx, userId, sessionDocId, input.thumbId, MAX_THUMB_BYTES);
      if (IMAGE_TYPES.has(normalizeMime(thumb.contentType))) thumbId = thumb._id;
    }
    if (thumbId) {
      const file = await ctx.db
        .query("files")
        .withIndex("by_storage", (q) => q.eq("storageId", stored._id))
        .unique();
      if (file && file.thumbId === undefined) await ctx.db.patch(file._id, { thumbId });
    }
    claimed.push({
      storageId: stored._id,
      thumbId,
      name: cleanName(input.name),
      mimeType,
      size: stored.size,
      kind,
      width: kind === "image" ? dimension(input.width) : undefined,
      height: kind === "image" ? dimension(input.height) : undefined,
    });
  }
  return claimed;
}

/**
 * A transcript item's attachments as its computer sends them: uploads are claimed for the session (type and size read
 * from storage); a file only on the computer (no `storageId`) is kept by name.
 */
export async function claimEventAttachments(
  ctx: MutationCtx,
  userId: Id<"users">,
  sessionDocId: Id<"sessions">,
  attachments: Attachment[],
): Promise<Attachment[]> {
  const claimed: Attachment[] = [];
  for (const item of attachments.slice(0, MAX_ATTACHMENTS)) {
    if (!item.storageId) {
      claimed.push({
        name: cleanName(item.name),
        mimeType: normalizeMime(item.mimeType),
        size: Math.max(0, item.size),
        kind: item.kind,
        width: dimension(item.width),
        height: dimension(item.height),
      });
      continue;
    }
    const { storageId, thumbId, name, width, height } = item;
    claimed.push(...(await claimAttachments(ctx, userId, sessionDocId, [{ storageId, thumbId, name, width, height }])));
  }
  return claimed;
}

/** Attachments with the URLs viewers read them from (`null` once the upload is gone). */
export async function withUrls(
  ctx: QueryCtx,
  attachments: Attachment[] | undefined,
): Promise<AttachmentWithUrls[] | undefined> {
  if (!attachments || attachments.length === 0) return undefined;
  return await Promise.all(
    attachments.map(async (item) => ({
      ...item,
      url: item.storageId ? await ctx.storage.getUrl(item.storageId) : null,
      thumbUrl: item.thumbId ? await ctx.storage.getUrl(item.thumbId) : null,
    })),
  );
}

/**
 * Which images, by the storage's SHA-256 (base64), the relay already holds for this session (crok's own id) of the
 * calling computer: a computer re-reading a transcript from disk links them again instead of uploading them twice.
 */
export const known = query({
  args: { sessionId: v.string(), sha256: v.array(v.string()) },
  handler: async (ctx, { sessionId, sha256 }) => {
    const viewer = await requireViewer(ctx);
    const device = viewer.device;
    if (!device || device.kind !== "computer") fail("FORBIDDEN", "Only a linked computer can do this.");
    const session = await ctx.db
      .query("sessions")
      .withIndex("by_user_session", (q) => q.eq("userId", viewer.user._id).eq("sessionId", sessionId))
      .unique();
    const found: Record<string, { storageId: Id<"_storage">; thumbId: Id<"_storage"> | null }> = {};
    if (!session || session.deviceId !== device._id) return found;
    for (const hash of sha256.slice(0, 100)) {
      const file = await ctx.db
        .query("files")
        .withIndex("by_session_sha", (q) => q.eq("sessionDocId", session._id).eq("sha256", hash))
        .first();
      if (!file || !(await ctx.db.system.get(file.storageId))) continue;
      const thumb = file.thumbId && (await ctx.db.system.get(file.thumbId)) ? file.thumbId : null;
      found[hash] = { storageId: file.storageId, thumbId: thumb };
    }
    return found;
  },
});

/** Deletes a session's uploads, a batch at a time (the session was removed, or its transcript expired). */
export const deleteSessionFiles = internalMutation({
  args: { sessionDocId: v.id("sessions") },
  handler: async (ctx, { sessionDocId }) => {
    const batch = await ctx.db
      .query("files")
      .withIndex("by_session", (q) => q.eq("sessionDocId", sessionDocId))
      .take(DELETE_BATCH);
    for (const file of batch) {
      if (await ctx.db.system.get(file.storageId)) await ctx.storage.delete(file.storageId);
      await ctx.db.delete(file._id);
    }
    if (batch.length === DELETE_BATCH) {
      await ctx.scheduler.runAfter(0, internal.files.deleteSessionFiles, { sessionDocId });
    }
    return null;
  },
});

/**
 * Hourly: deletes uploads no prompt claimed within a day (a photo attached and then removed, an app killed before
 * sending). It walks the storage in upload order and remembers how far it got.
 */
export const sweep = internalMutation({
  args: {},
  handler: async (ctx) => {
    const state = await ctx.db.query("fileSweeps").first();
    const from = state?.scannedThrough ?? 0;
    const cutoff = Date.now() - UNCLAIMED_KEEP_MS;
    const batch = await ctx.db.system
      .query("_storage")
      .withIndex("by_creation_time", (q) => q.gt("_creationTime", from).lt("_creationTime", cutoff))
      .order("asc")
      .take(SWEEP_BATCH);
    let through = from;
    let deleted = 0;
    for (const stored of batch) {
      through = stored._creationTime;
      const claimed = await ctx.db
        .query("files")
        .withIndex("by_storage", (q) => q.eq("storageId", stored._id))
        .first();
      if (!claimed) {
        await ctx.storage.delete(stored._id);
        deleted += 1;
      }
    }
    if (state) {
      if (through !== from) await ctx.db.patch(state._id, { scannedThrough: through });
    } else {
      await ctx.db.insert("fileSweeps", { scannedThrough: through });
    }
    if (batch.length === SWEEP_BATCH) await ctx.scheduler.runAfter(0, internal.files.sweep, {});
    return { scanned: batch.length, deleted };
  },
});
