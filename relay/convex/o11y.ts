import { v } from "convex/values";
import { internal } from "./_generated/api";
import type { QueryCtx } from "./_generated/server";
import { action, internalAction, internalMutation, internalQuery, query } from "./_generated/server";
import { fail, getViewer } from "./lib/auth";
import { grafanaClient } from "./lib/o11y/grafana";
import { PAGES, buildPage, normalize } from "./lib/o11y/pages";
import { message } from "./lib/o11y/read";

/**
 * The phones' o11y tab (relay/DESIGN.md §3 "o11y"): pages built from the relay owner's Grafana stack, kept in
 * `o11yPages` and read only by the accounts `O11Y_VIEWERS` names.
 */

/** A page this young is served as it is; `force` (pull to refresh) lowers it. */
const FRESH_MS = 90_000;
const FORCE_FRESH_MS = 10_000;
/** A refresh that started this long ago without finishing is presumed dead and may be taken over. */
const BUSY_MS = 60_000;

type Access = "ok" | "forbidden" | "unconfigured";

function grafanaConfig(): { url: string; token: string } | null {
  const url = process.env.GRAFANA_URL?.trim();
  const token = process.env.GRAFANA_TOKEN?.trim();
  return url && token ? { url, token } : null;
}

/** Whether the caller may read the pages: signed in, a token configured, and named in `O11Y_VIEWERS`. */
async function access(ctx: QueryCtx): Promise<Access> {
  const viewer = await getViewer(ctx);
  if (!viewer) fail("UNAUTHENTICATED", "Sign in first.");
  if (!grafanaConfig()) return "unconfigured";
  const allowed = (process.env.O11Y_VIEWERS ?? "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);
  const { user } = viewer;
  const subject = user.tokenIdentifier.split("|").pop() ?? "";
  const names = [user._id, user.email ?? "", user.tokenIdentifier, subject].map((name) => name.toLowerCase()).filter(Boolean);
  return names.some((name) => allowed.includes(name)) ? "ok" : "forbidden";
}

function keyOf(page: string, range: string, lang: string): string {
  return `${page}|${range}|${lang}`;
}

function resolve(args: { page: string; range?: string; lang?: string }) {
  const def = PAGES[args.page];
  if (!def) fail("NOT_FOUND", "No such page.");
  const { range, lang } = normalize(def, args.range, args.lang);
  return { def, range, lang, key: keyOf(def.id, range, lang) };
}

const pageArgs = { page: v.string(), range: v.optional(v.string()), lang: v.optional(v.string()) };

/** The cached page (whatever its age) and whether a refresh is building a newer one. */
export const page = query({
  args: pageArgs,
  handler: async (ctx, args) => {
    const state = await access(ctx);
    if (state !== "ok") return { state };
    const { key } = resolve(args);
    const row = await ctx.db
      .query("o11yPages")
      .withIndex("by_key", (q) => q.eq("key", key))
      .unique();
    return {
      state,
      page: row?.page ?? null,
      builtAt: row?.builtAt ?? null,
      refreshing: row?.refreshingSince !== undefined,
      error: row?.error ?? null,
    };
  },
});

export const gate = internalQuery({
  args: {},
  handler: async (ctx): Promise<Access> => access(ctx),
});

/** Claims the refresh of `key`, unless its page is fresh enough or another refresh is building it. */
export const begin = internalMutation({
  args: { key: v.string(), freshFor: v.number() },
  handler: async (ctx, { key, freshFor }) => {
    const now = Date.now();
    const row = await ctx.db
      .query("o11yPages")
      .withIndex("by_key", (q) => q.eq("key", key))
      .unique();
    const builtAt = row?.builtAt ?? null;
    if (builtAt !== null && now - builtAt < freshFor) return { status: "fresh" as const, builtAt };
    if (row?.refreshingSince !== undefined && now - row.refreshingSince < BUSY_MS) return { status: "busy" as const, builtAt };
    if (row) await ctx.db.patch(row._id, { refreshingSince: now, updatedAt: now });
    else await ctx.db.insert("o11yPages", { key, refreshingSince: now, updatedAt: now });
    return { status: "go" as const, builtAt };
  },
});

export const store = internalMutation({
  args: { key: v.string(), page: v.any(), builtAt: v.number() },
  handler: async (ctx, { key, page, builtAt }) => {
    const row = await ctx.db
      .query("o11yPages")
      .withIndex("by_key", (q) => q.eq("key", key))
      .unique();
    const fields = { page, builtAt, refreshingSince: undefined, error: undefined, updatedAt: Date.now() };
    if (row) await ctx.db.patch(row._id, fields);
    else await ctx.db.insert("o11yPages", { key, ...fields });
  },
});

export const failed = internalMutation({
  args: { key: v.string(), error: v.string() },
  handler: async (ctx, { key, error }) => {
    const row = await ctx.db
      .query("o11yPages")
      .withIndex("by_key", (q) => q.eq("key", key))
      .unique();
    if (row) await ctx.db.patch(row._id, { refreshingSince: undefined, error, updatedAt: Date.now() });
  },
});

type RefreshResult = { status: "built" | "fresh" | "busy" | "failed"; builtAt: number | null; error: string | null };

/** Rebuilds the page from Grafana when it is stale; the phones see the new one through `o11y:page`. */
export const refresh = action({
  args: { ...pageArgs, force: v.optional(v.boolean()) },
  handler: async (ctx, args): Promise<RefreshResult> => {
    const state = await ctx.runQuery(internal.o11y.gate, {});
    if (state === "forbidden") fail("FORBIDDEN", "This account can't see the relay's Grafana stack.");
    if (state === "unconfigured") fail("NOT_CONFIGURED", "The relay has no Grafana token yet.");
    const { def, range, lang, key } = resolve(args);
    const claim = await ctx.runMutation(internal.o11y.begin, { key, freshFor: args.force ? FORCE_FRESH_MS : FRESH_MS });
    if (claim.status !== "go") return { status: claim.status, builtAt: claim.builtAt, error: null };
    const config = grafanaConfig()!;
    try {
      const built = await buildPage(grafanaClient(config.url, config.token), def.id, range, lang);
      // A page is plain JSON: this drops undefined fields and non-finite numbers Convex would refuse.
      const page = JSON.parse(JSON.stringify(built));
      await ctx.runMutation(internal.o11y.store, { key, page, builtAt: built.builtAt });
      return { status: "built", builtAt: built.builtAt, error: null };
    } catch (error) {
      const text = message(error);
      await ctx.runMutation(internal.o11y.failed, { key, error: text });
      return { status: "failed", builtAt: claim.builtAt, error: text };
    }
  },
});

/**
 * For the deployment's owner (`npx convex run o11y:check '{"page":"home"}'`): builds a page with the configured
 * token, without caching it, and says what each section came out as.
 */
export const check = internalAction({
  args: { page: v.optional(v.string()), range: v.optional(v.string()), lang: v.optional(v.string()) },
  handler: async (_ctx, args) => {
    const config = grafanaConfig();
    if (!config) return { ok: false, error: "GRAFANA_URL and GRAFANA_TOKEN are not both set." };
    const started = Date.now();
    const built = await buildPage(grafanaClient(config.url, config.token), args.page ?? "home", args.range, args.lang);
    return {
      ok: built.sections.every((s) => s.block.kind !== "error"),
      seconds: (Date.now() - started) / 1000,
      bytes: JSON.stringify(built).length,
      sections: built.sections.map((s) => `${s.title ?? ""}: ${s.block.kind === "error" ? `error: ${s.block.message}` : s.block.kind}`),
      viewers: (process.env.O11Y_VIEWERS ?? "").split(",").filter((x) => x.trim()).length,
    };
  },
});
