import type { Doc } from "../_generated/dataModel";

/**
 * Refresh (relay/DESIGN.md §2, "Every session, not only running ones"): someone asked for a fresh listing after the
 * computer's last catalog upload began, so the next crok there to ask (`bridge:beginCatalog`) lists every session again
 * at once, whichever crok holds the catalog and however recently it listed them.
 */
export function refreshWanted(sync: Doc<"catalogSyncs">): boolean {
  return sync.refreshAt !== undefined && sync.refreshAt > sync.startedAt;
}

/** A refresh asked for at or after `since` that no finished upload has answered yet. */
export function refreshPending(sync: Doc<"catalogSyncs">, since: number): boolean {
  if (sync.refreshAt === undefined || sync.refreshAt < since) return false;
  return refreshWanted(sync) || sync.finishedAt === undefined;
}
