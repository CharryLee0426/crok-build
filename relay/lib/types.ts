import type { FunctionReturnType } from "convex/server";
import type { api } from "@/convex/_generated/api";
import type { Id } from "@/convex/_generated/dataModel";

/** Row shapes straight from the relay's API (relay/convex), so the UI follows the contract when it changes. */
export type SessionRow = FunctionReturnType<typeof api.sessions.list>[number];
/** One project section of the main list (`sessions:groups`): its sessions are rows like `SessionRow`. */
export type ProjectGroup = FunctionReturnType<typeof api.sessions.groups>[number];
export type SessionDetail = FunctionReturnType<typeof api.sessions.get>;
export type TranscriptEvent = FunctionReturnType<typeof api.sessions.events>["page"][number];
export type PromptCommand = FunctionReturnType<typeof api.commands.forSession>[number];
export type DeviceRow = FunctionReturnType<typeof api.devices.list>[number];
export type PendingLogin = NonNullable<FunctionReturnType<typeof api.deviceAuth.pendingLogin>>;

/** What the session's computer can run (`sessions:get(...).models`), each model with its thinking levels. */
export type ModelChoice = NonNullable<SessionDetail["models"]>[number];
export type EffortChoice = ModelChoice["efforts"][number];
/** `sessions:commands`: the agent's slash commands, without the leading `/`. */
export type SlashCommand = FunctionReturnType<typeof api.sessions.commands>["commands"][number];

export type SessionStatus = SessionRow["status"];
export type SessionId = Id<"sessions">;
export type CommandId = Id<"commands">;

/** `commands:requestInfo` result (DESIGN.md §3); every field may be missing. */
export type SessionInfoResult = {
  model?: string;
  effort?: string;
  cwd?: string;
  gitBranch?: string;
  title?: string;
  createdAt?: number;
  /** The session's average output speed, when its computer reported one. */
  outputTokensPerSecond?: number;
  usage?: {
    inputTokens?: number;
    outputTokens?: number;
    cachedTokens?: number;
    reasoningTokens?: number;
    costUsd?: number;
  };
  context?: { used?: number; window?: number };
  messages?: number;
  sessionId?: string;
};

/** A prompt this browser sent, shown at once (Telegram's clock) until the relay's command row takes over. */
export type OutboxItem = {
  clientId: string;
  text: string;
  createdAt: number;
  /** Set when `commands:sendPrompt` itself failed (network, offline); the relay never saw it. */
  error?: string;
};

/** What the transcript shows below the loaded events for a prompt that has no user event yet. */
export type PendingPrompt = {
  key: string;
  text: string;
  createdAt: number;
  tick: "sending" | "pending" | "delivered" | "failed";
  error?: string | null;
  /** Relay command id once there is one (Retry/Delete go through `commands:retry` / `discard`). */
  commandId?: CommandId;
  clientId?: string | null;
};
