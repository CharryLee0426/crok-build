import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { fail } from "./auth";

/**
 * Sessions made by `sessions:create` carry this id prefix (and the creator's client id) until the computer that opens
 * them swaps in crok's own session id (`bridge:bindSession`).
 */
export const STARTING_PREFIX = "pending:";

export function isStarting(session: Pick<Doc<"sessions">, "sessionId">): boolean {
  return session.sessionId.startsWith(STARTING_PREFIX);
}

const TITLE_MAX = 80;

/** A new session's title until crok names it: its first prompt's first line. */
export function titleFromPrompt(text: string | undefined): string {
  const line = (text ?? "")
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l.length > 0);
  if (!line) return "New session";
  return line.length > TITLE_MAX ? `${line.slice(0, TITLE_MAX - 1)}…` : line;
}

/** An absolute folder on a computer (Unix, Windows drive, or UNC). */
export function isAbsolutePath(path: string): boolean {
  return path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path) || path.startsWith("\\\\");
}

/** Whether a crok process handles a command type the first relay did not have (`create`, `config`, `git`). */
export function supports(host: Pick<Doc<"hosts">, "features">, type: Doc<"commands">["type"]): boolean {
  if (type !== "create" && type !== "config" && type !== "git") return true;
  return host.features?.includes(type) ?? false;
}

/**
 * A model and thinking level chosen when starting a session on another computer, checked against that computer's
 * `models` when the relay has them: `effort` is what the bridge applies (an option id), `effortValue` what the
 * session row stores (the level itself, `low`, `high`, …).
 */
export type SessionSetup = {
  model?: string;
  effort?: string;
  effortValue?: string;
};

export function sessionSetup(
  models: Doc<"modelLists">["models"] | null,
  model: string | undefined,
  effort: string | undefined,
): SessionSetup {
  const wantedModel = model?.trim() || undefined;
  const wantedEffort = effort?.trim() || undefined;
  if (!wantedModel && !wantedEffort) return {};
  if (wantedEffort && !wantedModel) fail("INVALID", "Choose a model with the thinking level.");
  const chosen = wantedModel && models ? models.find((m) => m.id === wantedModel) : undefined;
  if (wantedModel && models && models.length > 0 && !chosen) {
    fail("INVALID", "That model is not available on this computer.");
  }
  const level = chosen?.efforts.find((e) => e.id === wantedEffort || e.value === wantedEffort);
  if (wantedEffort && chosen && !level) {
    fail("INVALID", "That thinking level is not available for this model.");
  }
  return {
    model: wantedModel,
    effort: level?.id ?? wantedEffort,
    effortValue: level?.value ?? level?.id ?? wantedEffort,
  };
}

/** The models the session's computer can run, while it is online (null: nothing to choose from now). */
export async function modelsFor(
  ctx: QueryCtx,
  device: Doc<"devices"> | null,
): Promise<Doc<"modelLists">["models"] | null> {
  if (!device || !device.online) return null;
  const row = await ctx.db
    .query("modelLists")
    .withIndex("by_device", (q) => q.eq("deviceId", device._id))
    .first();
  return row?.models ?? null;
}

/**
 * The list `sessions:get` still embeds for clients from before `devices:models` was their source: up to the 200 models
 * the first relay took. A longer list (OpenRouter's) would go out again with every transcript item, since the query
 * re-runs whenever the session row changes, so those clients see none, as before; current ones subscribe to
 * `devices:models`, which changes only with the list.
 */
export const EMBEDDED_MODELS_MAX = 200;

export function embeddedModels(
  models: Doc<"modelLists">["models"] | null,
): Doc<"modelLists">["models"] | null {
  return models && models.length <= EMBEDDED_MODELS_MAX ? models : null;
}

/** Appends one transcript item to a session no host writes now (a failure the relay itself reports). */
export async function appendNotice(
  ctx: MutationCtx,
  sessionDocId: Id<"sessions">,
  kind: "error" | "system",
  text: string,
) {
  const session = await ctx.db.get(sessionDocId);
  if (!session) return;
  const seq = session.eventSeq + 1;
  const now = Date.now();
  await ctx.db.insert("events", {
    sessionDocId,
    userId: session.userId,
    seq,
    key: `relay-${now}-${seq}`,
    kind,
    text,
    at: now,
  });
  await ctx.db.patch(sessionDocId, { eventSeq: seq, preview: text.slice(0, 280), previewKind: kind });
}
