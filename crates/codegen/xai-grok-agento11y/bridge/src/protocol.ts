// The lines crok writes to the bridge's stdin, one JSON object per line.
// The Rust side is `xai_grok_sampler::observe::GenerationRecord`; keep the two in step.
// Field names and shapes follow the agento11y SDK's GenerationStart / GenerationResult,
// with dates as epoch milliseconds because JSON has no Date.

import type {
  GenerationResult,
  GenerationStart,
  Message,
  ModelRef,
  TokenUsage,
  ToolDefinition,
} from "@grafana/agento11y-core";

/** One model API call crok made, sent once the call has finished or failed. */
export interface GenerationLine {
  type: "generation";
  start: StartFields;
  result: ResultFields;
  /** When the first streamed token arrived; absent when none did. */
  firstTokenAtMs?: number;
  /** Set when the call failed; `result` then carries the request side only. */
  error?: CallError;
  /**
   * crok's own attributes for the call's span, which the SDK has no field for: `crok.backend`,
   * `crok.cost.usd` with `crok.cost.source` (`provider` or `list_price`), `crok.cancelled`.
   */
  spanAttributes?: Record<string, SpanAttributeValue>;
}

export type SpanAttributeValue = string | number | boolean;

/** Asks the bridge to export everything it holds now, without waiting for the timers. */
export interface FlushLine {
  type: "flush";
}

export type Line = GenerationLine | FlushLine;

export interface StartFields {
  id: string;
  mode: "SYNC" | "STREAM";
  model: ModelRef;
  startedAtMs: number;
  conversationId?: string;
  conversationTitle?: string;
  agentName?: string;
  agentVersion?: string;
  systemPrompt?: string;
  maxTokens?: number;
  temperature?: number;
  topP?: number;
  toolChoice?: string;
  thinkingEnabled?: boolean;
  parentGenerationIds?: string[];
  tools?: ToolDefinition[];
  tags?: Record<string, string>;
  metadata?: Record<string, unknown>;
}

export interface ResultFields {
  completedAtMs: number;
  responseId?: string;
  responseModel?: string;
  input?: Message[];
  output?: Message[];
  usage?: TokenUsage;
  stopReason?: string;
  metadata?: Record<string, unknown>;
}

export interface CallError {
  message: string;
  /** HTTP status when the provider answered with one; the SDK files 429 as rate_limit, 401 as auth_error. */
  statusCode?: number;
}

/** Parses one stdin line; `undefined` for blank lines, an Error for anything malformed. */
export function parseLine(text: string): Line | Error | undefined {
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  let value: unknown;
  try {
    value = JSON.parse(trimmed);
  } catch (error) {
    return new Error(`not JSON: ${(error as Error).message}`);
  }
  if (!isRecord(value)) {
    return new Error("not a JSON object");
  }
  if (value.type === "flush") {
    return { type: "flush" };
  }
  if (value.type !== "generation") {
    return new Error(`unknown line type ${JSON.stringify(value.type)}`);
  }
  const start = value.start;
  const result = value.result;
  if (!isRecord(start) || typeof start.id !== "string" || !isRecord(start.model)) {
    return new Error("generation line without start.id or start.model");
  }
  if (typeof start.startedAtMs !== "number" || !isRecord(result) || typeof result.completedAtMs !== "number") {
    return new Error("generation line without startedAtMs or completedAtMs");
  }
  return value as unknown as GenerationLine;
}

/** The SDK seed for a line: crok's own start time, so spans and duration metrics match the real call. */
export function toStart(fields: StartFields): GenerationStart {
  const { startedAtMs, mode: _mode, ...rest } = fields;
  return { ...rest, startedAt: new Date(startedAtMs) };
}

export function toResult(fields: ResultFields): GenerationResult {
  const { completedAtMs, ...rest } = fields;
  return { ...rest, completedAt: new Date(completedAtMs) };
}

/** The line's span attributes that a span can hold (strings, finite numbers, booleans); the rest is dropped. */
export function spanAttributesOf(line: GenerationLine): Record<string, SpanAttributeValue> | undefined {
  const given: unknown = line.spanAttributes;
  if (!isRecord(given)) {
    return undefined;
  }
  const kept = Object.entries(given).filter(
    (entry): entry is [string, SpanAttributeValue] =>
      typeof entry[1] === "string" ||
      typeof entry[1] === "boolean" ||
      (typeof entry[1] === "number" && Number.isFinite(entry[1])),
  );
  return kept.length > 0 ? Object.fromEntries(kept) : undefined;
}

/**
 * An Error the SDK can classify. A generation recorder keeps only the message and reads the
 * HTTP status out of its text (429 is rate_limit, 401/403 auth_error, 5xx server_error),
 * so the status leads the message.
 */
export function toCallError(error: CallError): Error {
  const status = error.statusCode;
  const message = typeof status === "number" ? `HTTP ${status}: ${error.message}` : error.message;
  return Object.assign(new Error(message), typeof status === "number" ? { status } : {});
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
