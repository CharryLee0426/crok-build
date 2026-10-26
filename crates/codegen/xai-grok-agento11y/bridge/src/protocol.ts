// The lines crok writes to the bridge's stdin, one JSON object per line.
// The Rust side is `xai_grok_sampler::observe::GenerationRecord` for model calls and
// `observe_harness.rs` for the rest; keep them in step.
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
  /** The turn span the call's span is a child of; absent outside a turn (side calls between turns). */
  parent?: SpanRef | null;
}

/** A span in a turn's trace, made by crok: W3C ids in lowercase hex. */
export interface SpanRef {
  traceId: string;
  spanId: string;
}

/** One turn, sent when it ends, after the calls and tool runs under it. */
export interface TurnLine {
  type: "turn";
  span: SpanRef;
  /** For a sub-agent's turn: the turn of the session that started it. */
  parent?: SpanRef | null;
  conversationId: string;
  conversationTitle?: string | null;
  agentName: string;
  startedAtMs: number;
  completedAtMs: number;
  error?: string | null;
  /** `crok.turn.outcome`, `crok.turn_index`, `crok.model_calls`, `crok.tool_calls`, ... */
  attributes?: Record<string, SpanAttributeValue>;
  tags?: Record<string, string>;
}

/** One tool run, as an `execute_tool` span under its turn. */
export interface ToolLine {
  type: "tool";
  parent?: SpanRef | null;
  conversationId: string;
  conversationTitle?: string | null;
  agentName: string;
  toolName: string;
  toolCallId: string;
  requestModel?: string | null;
  startedAtMs: number;
  completedAtMs: number;
  error?: string | null;
  /** `crok.tool.outcome`, `crok.tool.kind`, `crok.tool.exit_code`, ... */
  attributes?: Record<string, SpanAttributeValue>;
  tags?: Record<string, string>;
}

/** A workflow step beside the generations: a permission or hook decision, a compaction. */
export interface StepLine {
  type: "step";
  id: string;
  parent?: SpanRef | null;
  conversationId: string;
  agentName: string;
  stepName: string;
  startedAtMs: number;
  completedAtMs: number;
  inputState?: Record<string, unknown>;
  outputState?: Record<string, unknown>;
  error?: string | null;
  linkedGenerationIds?: string[];
  tags?: Record<string, string>;
}

/** One of crok's own verdicts, as a score on a generation. */
export interface ScoreLine {
  type: "score";
  scoreId: string;
  evaluatorId: string;
  scoreKey: string;
  value: { number: number } | { bool: boolean } | { string: string };
  passed?: boolean | null;
  explanation?: string | null;
  generationId: string;
  conversationId?: string | null;
  traceId?: string | null;
  spanId?: string | null;
}

/** The user's rating of a conversation. */
export interface RatingLine {
  type: "rating";
  conversationId: string;
  ratingId: string;
  rating: "CONVERSATION_RATING_VALUE_GOOD" | "CONVERSATION_RATING_VALUE_BAD";
  comment?: string | null;
  generationId?: string | null;
  category?: string | null;
}

/** A guard check: the tool calls the model returned (postflight), or the tool results about to go to it (preflight). */
export interface GuardLine {
  type: "guard";
  phase: "preflight" | "postflight";
  conversationId: string;
  agentName: string;
  model: { provider: string; name: string };
  traceId?: string | null;
  spanId?: string | null;
  input: { messages?: Message[]; output?: Message[] };
  tags?: Record<string, string>;
}

export type HarnessLine = TurnLine | ToolLine | StepLine | ScoreLine | RatingLine | GuardLine;

export type SpanAttributeValue = string | number | boolean;

/** Asks the bridge to export everything it holds now, without waiting for the timers. */
export interface FlushLine {
  type: "flush";
}

export type Line = GenerationLine | FlushLine | HarnessLine;

const HARNESS_TYPES = new Set(["turn", "tool", "step", "score", "rating", "guard"]);

/** Fields each harness line must have, as `typeof` names. */
const HARNESS_FIELDS: Record<string, Record<string, string>> = {
  turn: { span: "object", conversationId: "string", agentName: "string", startedAtMs: "number", completedAtMs: "number" },
  tool: { conversationId: "string", agentName: "string", toolName: "string", toolCallId: "string", startedAtMs: "number", completedAtMs: "number" },
  step: { id: "string", conversationId: "string", stepName: "string", startedAtMs: "number", completedAtMs: "number" },
  score: { scoreId: "string", evaluatorId: "string", scoreKey: "string", value: "object", generationId: "string" },
  rating: { conversationId: "string", ratingId: "string", rating: "string" },
  guard: { phase: "string", conversationId: "string", model: "object", input: "object" },
};

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
  if (typeof value.type === "string" && HARNESS_TYPES.has(value.type)) {
    const required = HARNESS_FIELDS[value.type] ?? {};
    const missing = Object.entries(required).filter(([field, kind]) => {
      const got = value[field];
      return kind === "object" ? !isRecord(got) : typeof got !== kind;
    });
    if (missing.length > 0) {
      return new Error(`${value.type} line without ${missing.map(([field]) => field).join(", ")}`);
    }
    return value as unknown as HarnessLine;
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
export function spanAttributesOf(
  line: GenerationLine | TurnLine | ToolLine,
): Record<string, SpanAttributeValue> | undefined {
  const given: unknown = line.type === "generation" ? line.spanAttributes : line.attributes;
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
/** A span ref crok sent, when it is a valid W3C trace id and span id. */
export function validSpanRef(ref: unknown): SpanRef | undefined {
  if (!isRecord(ref)) {
    return undefined;
  }
  const { traceId, spanId } = ref;
  return typeof traceId === "string" &&
    typeof spanId === "string" &&
    /^[0-9a-f]{32}$/.test(traceId) &&
    /^[0-9a-f]{16}$/.test(spanId) &&
    !/^0+$/.test(traceId) &&
    !/^0+$/.test(spanId)
    ? { traceId, spanId }
    : undefined;
}

/** Tags with string values only; the rest is dropped. */
export function stringTags(tags: unknown): Record<string, string> | undefined {
  if (!isRecord(tags)) {
    return undefined;
  }
  const kept = Object.entries(tags).filter((entry): entry is [string, string] => typeof entry[1] === "string");
  return kept.length > 0 ? Object.fromEntries(kept) : undefined;
}

export function toCallError(error: CallError): Error {
  const status = error.statusCode;
  const message = typeof status === "number" ? `HTTP ${status}: ${error.message}` : error.message;
  return Object.assign(new Error(message), typeof status === "number" ? { status } : {});
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
