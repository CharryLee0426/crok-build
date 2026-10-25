// What crok reports around its model calls (`observe_harness.rs` in the sampler): each turn as the
// root span of its trace, each tool run as an `execute_tool` span under it, workflow steps
// (permission and hook decisions, compaction), crok's own verdicts as scores, the user's ratings,
// and guard checks against the stack's hook rules.

import type { Agento11yClient, WorkflowStep } from "@grafana/agento11y-core";
import { type Attributes, context, SpanKind, SpanStatusCode, type Tracer } from "@opentelemetry/api";

import { describe, type Log } from "./log.js";
import { contextOf, type CrokSpanAttributes, type PresetIds } from "./otel.js";
import {
  type GuardLine,
  type HarnessLine,
  type RatingLine,
  type ScoreLine,
  type StepLine,
  spanAttributesOf,
  stringTags,
  type ToolLine,
  type TurnLine,
  validSpanRef,
} from "./protocol.js";

export interface HarnessDeps {
  client: Agento11yClient;
  tracer: Tracer;
  ids: PresetIds;
  spanAttributes: CrokSpanAttributes;
  scores: ScoreExporter;
  log: Log;
  agentVersion?: string;
  /** Guard checks go to the stack unless CROK_AGENTO11Y_GUARDS turns them off. */
  guards: boolean;
  /** Ratings and guard checks still in flight; flush and shutdown wait for them. */
  pending: Set<Promise<unknown>>;
}

/** Records one harness line. Returns why it could not be, for the bridge log. */
export function recordHarness(deps: HarnessDeps, line: HarnessLine): Error | undefined {
  switch (line.type) {
    case "turn":
      return recordTurn(deps, line);
    case "tool":
      return recordTool(deps, line);
    case "step":
      deps.client.enqueueWorkflowStep(toWorkflowStep(line, deps.agentVersion));
      return undefined;
    case "score":
      deps.scores.add(line);
      return undefined;
    case "rating":
      track(deps, submitRating(deps, line));
      return undefined;
    case "guard":
      if (deps.guards) {
        track(deps, evaluateGuard(deps, line));
      }
      return undefined;
  }
}

/** Waits for the ratings and guard checks in flight. */
export async function settle(deps: Pick<HarnessDeps, "pending">): Promise<void> {
  while (deps.pending.size > 0) {
    await Promise.allSettled([...deps.pending]);
  }
}

function track(deps: HarnessDeps, work: Promise<unknown>): void {
  const tracked = work.catch((error: unknown) => deps.log.warn(describe(error)));
  deps.pending.add(tracked);
  void tracked.finally(() => deps.pending.delete(tracked));
}

/**
 * The turn's span, with the ids crok gave it when the turn started: its generations and tool runs,
 * written earlier, already name it as their parent. A sub-agent's turn is a child of the turn that
 * started it.
 */
function recordTurn(deps: HarnessDeps, line: TurnLine): Error | undefined {
  const own = validSpanRef(line.span);
  if (own === undefined) {
    return new Error("turn line with an invalid span");
  }
  const attributes: Attributes = {
    "gen_ai.operation.name": "invoke_agent",
    "gen_ai.agent.name": line.agentName,
    "gen_ai.conversation.id": line.conversationId,
    ...tagAttributes({ ...deps.client.internalTags(), ...stringTags(line.tags) }),
    ...spanAttributesOf(line),
  };
  if (deps.agentVersion !== undefined && deps.agentVersion.length > 0) {
    attributes["gen_ai.agent.version"] = deps.agentVersion;
  }
  if (typeof line.conversationTitle === "string" && line.conversationTitle.length > 0) {
    attributes["agento11y.conversation.title"] = line.conversationTitle;
  }
  const span = deps.ids.with(own.traceId, own.spanId, () =>
    deps.tracer.startSpan(
      `invoke_agent ${line.agentName}`,
      { kind: SpanKind.INTERNAL, startTime: new Date(line.startedAtMs), attributes },
      contextOf(validSpanRef(line.parent)),
    ),
  );
  if (typeof line.error === "string" && line.error.length > 0) {
    span.setAttribute("error.type", "turn_error");
    span.setStatus({ code: SpanStatusCode.ERROR, message: line.error });
  } else {
    span.setStatus({ code: SpanStatusCode.OK });
  }
  span.end(new Date(line.completedAtMs));
  return undefined;
}

/** A tool run through the SDK's tool recorder, under its turn, with crok's attributes on its span. */
function recordTool(deps: HarnessDeps, line: ToolLine): Error | undefined {
  const run = (): Error | undefined => {
    const key = `tool:${line.toolCallId}`;
    deps.spanAttributes.expect(key, { ...spanAttributesOf(line), ...tagAttributes(stringTags(line.tags)) });
    const recorder = deps.client.startToolExecution({
      toolName: line.toolName,
      toolCallId: line.toolCallId,
      toolType: "function",
      conversationId: line.conversationId,
      conversationTitle: line.conversationTitle ?? undefined,
      agentName: line.agentName,
      agentVersion: deps.agentVersion,
      requestModel: line.requestModel ?? undefined,
      startedAt: new Date(line.startedAtMs),
    });
    try {
      if (typeof line.error === "string" && line.error.length > 0) {
        recorder.setCallError(new Error(line.error));
      }
      recorder.setResult({ completedAt: new Date(line.completedAtMs) });
    } finally {
      recorder.end();
      deps.spanAttributes.forget(key);
    }
    // The recorder reports the run's own failure here too; only a refused record is an error.
    const error = recorder.getError();
    return error !== undefined && error.message !== line.error ? error : undefined;
  };
  const parent = validSpanRef(line.parent);
  return parent === undefined ? run() : context.with(contextOf(parent), run);
}

export function toWorkflowStep(line: StepLine, agentVersion: string | undefined): WorkflowStep {
  const parent = validSpanRef(line.parent);
  return {
    id: line.id,
    conversationId: line.conversationId,
    stepName: line.stepName,
    framework: "crok",
    startedAt: new Date(line.startedAtMs),
    completedAt: new Date(line.completedAtMs),
    inputState: line.inputState,
    outputState: line.outputState,
    error: typeof line.error === "string" && line.error.length > 0 ? line.error : undefined,
    tags: stringTags(line.tags),
    linkedGenerationIds: line.linkedGenerationIds,
    agentName: line.agentName,
    agentVersion,
    traceId: parent?.traceId,
    spanId: parent?.spanId,
  };
}

async function submitRating(deps: HarnessDeps, line: RatingLine): Promise<void> {
  const response = await deps.client.submitConversationRating(line.conversationId, {
    ratingId: line.ratingId,
    rating: line.rating,
    comment: line.comment ?? undefined,
    generationId: line.generationId ?? undefined,
    source: "crok",
    metadata: typeof line.category === "string" ? { category: line.category } : undefined,
  });
  deps.log.info(
    `rating ${line.rating === "CONVERSATION_RATING_VALUE_GOOD" ? "good" : "bad"} on ${line.conversationId}: ` +
      `${response.summary.goodCount} good, ${response.summary.badCount} bad`,
  );
}

/**
 * Asks the stack's hook rules about a turn step. Warn mode: crok never waits for the answer; the
 * stack records a `warn` (or `deny`) on the conversation, and the bridge log says what fired.
 */
async function evaluateGuard(deps: HarnessDeps, line: GuardLine): Promise<void> {
  const response = await deps.client.evaluateHook(
    {
      phase: line.phase,
      context: {
        agentName: line.agentName,
        agentVersion: deps.agentVersion,
        model: line.model,
        tags: stringTags(line.tags),
        conversationId: line.conversationId,
        traceId: line.traceId ?? undefined,
        spanId: line.spanId ?? undefined,
      },
      input: line.input,
    },
    { enabled: true, phases: ["preflight", "postflight"], failOpen: true, timeoutMs: 10_000 },
  );
  const failed = response.evaluations.filter((evaluation) => !evaluation.passed);
  if (response.action === "deny" || failed.length > 0) {
    const rules = failed.map((evaluation) => `${evaluation.ruleId}${evaluation.reason ? ` (${evaluation.reason})` : ""}`);
    deps.log.info(`guard ${line.phase} on ${line.conversationId}: ${response.action}; ${rules.join(", ")}`);
  } else {
    deps.log.debug(`guard ${line.phase} on ${line.conversationId}: ${response.action}`);
  }
}

/** Tags as span attributes, the way the SDK writes them (`agento11y.tag.<key>`). */
function tagAttributes(tags: Record<string, string> | undefined): Attributes {
  const out: Attributes = {};
  for (const [key, value] of Object.entries(tags ?? {})) {
    out[`agento11y.tag.${key}`] = value;
  }
  return out;
}

export type ScorePoster = (url: string, headers: Record<string, string>, body: unknown) => Promise<unknown>;

/** Where scores go: the generation export's endpoint and headers (credentials included). */
export interface ScoreTarget {
  endpoint: string;
  headers?: Record<string, string>;
}

/**
 * crok's verdicts, sent in batches to `POST /api/v1/scores:export` on the generation endpoint, with
 * the generation export's credentials. A score names a generation, so the SDK's generation queue is
 * flushed first: the scored generation reaches the stack before its score.
 */
export class ScoreExporter {
  private queue: ScoreLine[] = [];
  private timer: ReturnType<typeof setTimeout> | undefined;
  private running: Promise<void> = Promise.resolve();

  constructor(
    private readonly client: Agento11yClient,
    private readonly log: Log,
    private readonly agentVersion: string | undefined,
    private readonly target: () => ScoreTarget,
    private readonly delayMs = 3_000,
    private readonly post: ScorePoster = postJson,
  ) {}

  add(line: ScoreLine): void {
    this.queue.push(line);
    if (this.timer === undefined) {
      this.timer = setTimeout(() => void this.flush(), this.delayMs);
      this.timer.unref?.();
    }
  }

  /** Sends everything queued; resolves when it is sent (or failed and logged). */
  flush(): Promise<void> {
    if (this.timer !== undefined) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
    this.running = this.running.then(() => this.sendQueued());
    return this.running;
  }

  private async sendQueued(): Promise<void> {
    while (this.queue.length > 0) {
      const batch = this.queue.splice(0, 100);
      try {
        await this.client.flush();
        const target = this.target();
        const base = target.endpoint.replace(/\/+$/, "");
        const response = await this.post(`${base}/api/v1/scores:export`, target.headers ?? {}, {
          scores: batch.map((line) => wireScore(line, this.agentVersion)),
        });
        const rejected = rejectedScores(response);
        if (rejected.length > 0) {
          this.log.warn(`${rejected.length} of ${batch.length} scores rejected: ${rejected.slice(0, 3).join("; ")}`);
        } else {
          this.log.debug(`scores export ok (${batch.length})`);
        }
      } catch (error) {
        this.log.warn(`scores export failed (${batch.length}): ${describe(error)}`);
      }
    }
  }
}

/** The score as `scores:export` takes it (snake_case, the Python SDK's `_serialize_score`). */
export function wireScore(line: ScoreLine, agentVersion: string | undefined): Record<string, unknown> {
  const out: Record<string, unknown> = {
    score_id: line.scoreId,
    evaluator_id: line.evaluatorId,
    evaluator_version: agentVersion !== undefined && agentVersion.length > 0 ? agentVersion : "1",
    score_key: line.scoreKey,
    value: line.value,
    generation_id: line.generationId,
    evaluator_kind: "heuristic",
    metadata: { source: "crok-harness" },
  };
  const optional: Record<string, unknown> = {
    conversation_id: line.conversationId,
    trace_id: line.traceId,
    span_id: line.spanId,
    passed: line.passed,
    explanation: line.explanation,
  };
  for (const [key, value] of Object.entries(optional)) {
    if (value !== undefined && value !== null && value !== "") {
      out[key] = value;
    }
  }
  return out;
}

function rejectedScores(response: unknown): string[] {
  if (typeof response !== "object" || response === null) {
    return [];
  }
  const results = (response as { results?: unknown }).results;
  if (!Array.isArray(results)) {
    return [];
  }
  return results
    .filter((result) => typeof result === "object" && result !== null && (result as { status?: unknown }).status === "rejected")
    .map((result) => {
      const { score_id: id, error } = result as { score_id?: unknown; error?: unknown };
      return `${String(id)}: ${String(error)}`;
    });
}

async function postJson(url: string, headers: Record<string, string>, body: unknown): Promise<unknown> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${text.slice(0, 300)}`);
  }
  return text.length > 0 ? JSON.parse(text) : {};
}
