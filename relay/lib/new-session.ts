/**
 * New sessions from the web (DESIGN.md §5 "New sessions"): the new-session screen's address, and the two hand-overs
 * that keep a prompt on screen across navigations. Module state is enough: both happen within one page load.
 */
import { newClientId } from "./browser";
import type { OutboxItem } from "./types";

/** `/new?device=…&path=…`: the new-session screen for one folder of one computer. */
export function newSessionHref(deviceId: string, path: string): string {
  return `/new?device=${encodeURIComponent(deviceId)}&path=${encodeURIComponent(path)}`;
}

/** Prompts `/new <prompt>` typed in a session, waiting for the new-session screen to send them. */
const queued = new Map<string, OutboxItem>();

/** Queues `/new <prompt>`'s prompt for the screen `newSessionHref(deviceId, path)` opens; its client id is fixed now. */
export function queueNewSessionPrompt(deviceId: string, path: string, text: string): void {
  queued.set(`${deviceId}\n${path}`, { clientId: newClientId(), text, createdAt: Date.now() });
}

/** The queued prompt for this folder, once. */
export function takeQueuedPrompt(deviceId: string, path: string): OutboxItem | undefined {
  const key = `${deviceId}\n${path}`;
  const item = queued.get(key);
  queued.delete(key);
  return item;
}

/**
 * The first prompt of a session just made by `sessions:create`, so the session screen shows it at once (with its clock)
 * until `commands:forSession` lists its `create` command.
 */
const handedOver = new Map<string, OutboxItem>();

export function handOverPrompt(sessionDocId: string, item: OutboxItem): void {
  handedOver.set(sessionDocId, item);
}

/** Read without taking: React may run a state initializer twice. `dropHandedOver` once the relay has the command. */
export function handedOverPrompt(sessionDocId: string): OutboxItem | undefined {
  return handedOver.get(sessionDocId);
}

export function dropHandedOver(sessionDocId: string): void {
  handedOver.delete(sessionDocId);
}
