import type { DeviceRow, ProjectGroup, SessionRow } from "@/lib/types";
import type { DevicesActions } from "../Devices";
import type { NewSessionTarget, OrderActions, SessionActions } from "../SessionList";

/** A page of the left column's stack (Telegram Web's left column): each slides in over the one before. */
export type LeftPage =
  | { kind: "sessions" }
  | { kind: "project"; key: string }
  | { kind: "archived" }
  | { kind: "profile" }
  | { kind: "devices" }
  | { kind: "appearance" }
  | { kind: "language" };

/** "Connecting…", "Updating…", "Waiting for network" replace the subtitle while the relay is not live. */
export type Connection = "live" | "connecting" | "updating" | "offline";

export type Account = { name: string | null; email: string | null; imageUrl: string | null };

/** Everything the left column shows; the live frame and the dev preview both build one. */
export type LeftData = {
  /** `sessions:groups`; undefined while loading. */
  groups: ProjectGroup[] | undefined;
  /** `sessions:list({archived: true})`. */
  archived: SessionRow[] | undefined;
  /** `devices:list`. */
  devices: DeviceRow[] | undefined;
  account: Account | null | undefined;
  connection: Connection;
  now: number;
  /** The web app's version (Profile › Version). */
  version: string;
};

export type LeftActions = {
  sessions: SessionActions;
  order: OrderActions;
  /** Opens the new-session screen for a project. */
  newSession: (target: NewSessionTarget) => void;
  devices: DevicesActions;
  signOut: () => void;
};
