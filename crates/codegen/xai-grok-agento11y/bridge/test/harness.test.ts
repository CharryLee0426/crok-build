// Feeds a turn's lines (generation, tool run, step, score, turn) through the real SDK client and
// real OTel providers (in-memory exporters) and checks that they form one trace under crok's ids.

import assert from "node:assert/strict";
import { test } from "node:test";

import { Agento11yClient, type WorkflowStep } from "@grafana/agento11y-core";
import { trace } from "@opentelemetry/api";
import { hrTimeToMilliseconds } from "@opentelemetry/core";
import { AggregationTemporality, InMemoryMetricExporter } from "@opentelemetry/sdk-metrics";
import { InMemorySpanExporter } from "@opentelemetry/sdk-trace";

import { type HarnessDeps, HarnessMetrics, recordHarness, ScoreExporter, settle, wireScore } from "../src/harness.js";
import type { Log } from "../src/log.js";
import { flushOtel, startOtel } from "../src/otel.js";
import { type GenerationLine, type HarnessLine, parseLine, type ScoreLine } from "../src/protocol.js";
import { recordGeneration } from "../src/record.js";

const logged: string[] = [];
const log: Log = {
  debug: (message) => logged.push(`DEBUG ${message}`),
  info: (message) => logged.push(`INFO ${message}`),
  warn: (message) => logged.push(`WARN ${message}`),
  error: (message) => logged.push(`ERROR ${message}`),
};
const spans = new InMemorySpanExporter();
const metricExporter = new InMemoryMetricExporter(AggregationTemporality.CUMULATIVE);
const otel = startOtel({
  serviceVersion: "9.9.9",
  metricIntervalMs: 3_600_000,
  log,
  spanExporter: spans,
  metricExporter,
});
const steps: WorkflowStep[] = [];
const client = new Agento11yClient({
  generationExport: { protocol: "http", endpoint: "http://127.0.0.1:9", auth: { mode: "none" } },
  generationExporter: {
    exportGenerations: async (request) => ({
      results: request.generations.map((g) => ({ generationId: g.id, accepted: true })),
    }),
    exportWorkflowSteps: async (request) => {
      steps.push(...request.workflowSteps);
      return { results: request.workflowSteps.map((s) => ({ stepId: s.id, accepted: true })) };
    },
  },
});
const posted: { url: string; body: unknown }[] = [];
const deps: HarnessDeps = {
  client,
  tracer: trace.getTracer("test"),
  metrics: new HarnessMetrics(),
  ids: otel.ids,
  spanAttributes: otel.spanAttributes,
  scores: new ScoreExporter(client, log, "2.1.0", () => ({ endpoint: "http://127.0.0.1:9/" }), 10, async (url, _headers, body) => {
    posted.push({ url, body });
    return { results: [] };
  }),
  log,
  agentVersion: "2.1.0",
  guards: false,
  pending: new Set(),
};

const t0 = Date.UTC(2026, 9, 25, 9, 0, 0);
const turn = { traceId: "0af7651916cd43dd8448eb211c80319c", spanId: "b7ad6b7169203331" };

function harness(line: unknown): void {
  const parsed = parseLine(JSON.stringify(line));
  assert.ok(parsed !== undefined && !(parsed instanceof Error), String(parsed));
  assert.notEqual(parsed.type, "generation");
  assert.notEqual(parsed.type, "flush");
  assert.equal(recordHarness(deps, parsed as HarnessLine), undefined);
}

test("a turn's generation and tool run are children of the turn span crok named", async () => {
  const generation: GenerationLine = {
    type: "generation",
    start: {
      id: "gen_turn1",
      mode: "STREAM",
      model: { provider: "anthropic", name: "claude-sonnet-5-5" },
      startedAtMs: t0 + 100,
      conversationId: "session-9",
      agentName: "crok",
    },
    result: { completedAtMs: t0 + 3_100, stopReason: "tool_use" },
    parent: turn,
  };
  assert.equal(recordGeneration(client, generation, otel.spanAttributes), undefined);
  harness({
    type: "tool",
    parent: turn,
    conversationId: "session-9",
    agentName: "crok",
    toolName: "run_terminal_command",
    toolCallId: "call_7",
    requestModel: "claude-sonnet-5-5",
    startedAtMs: t0 + 3_100,
    completedAtMs: t0 + 5_000,
    error: "exit status 1",
    attributes: { "crok.tool.outcome": "error", "crok.tool.kind": "mutating", "crok.tool.exit_code": 1 },
    tags: { repo: "crok-build", branch: "charlie/dev" },
  });
  harness({
    type: "turn",
    span: turn,
    parent: null,
    conversationId: "session-9",
    conversationTitle: "Fix the flaky test",
    agentName: "crok",
    startedAtMs: t0,
    completedAtMs: t0 + 41_000,
    attributes: { "crok.turn.outcome": "completed", "crok.model_calls": 1, "crok.tool_calls": 1 },
    tags: { origin: "relay" },
  });
  await client.flush();
  await flushOtel(otel);

  const finished = spans.getFinishedSpans();
  const root = finished.find((s) => s.name === "invoke_agent crok");
  assert.ok(root, finished.map((s) => s.name).join(","));
  assert.equal(root.spanContext().traceId, turn.traceId);
  assert.equal(root.spanContext().spanId, turn.spanId);
  assert.equal(root.parentSpanContext, undefined);
  assert.equal(root.attributes["gen_ai.operation.name"], "invoke_agent");
  assert.equal(root.attributes["crok.turn.outcome"], "completed");
  assert.equal(root.attributes["agento11y.tag.origin"], "relay");
  assert.equal(root.attributes["gen_ai.agent.version"], "2.1.0");
  assert.equal(hrTimeToMilliseconds(root.endTime) - hrTimeToMilliseconds(root.startTime), 41_000);

  const call = finished.find((s) => s.attributes["agento11y.generation.id"] === "gen_turn1");
  assert.ok(call);
  assert.equal(call.spanContext().traceId, turn.traceId);
  assert.equal(call.parentSpanContext?.spanId, turn.spanId);

  const tool = finished.find((s) => s.name.startsWith("execute_tool"));
  assert.ok(tool);
  assert.equal(tool.spanContext().traceId, turn.traceId);
  assert.equal(tool.parentSpanContext?.spanId, turn.spanId);
  assert.equal(tool.attributes["gen_ai.tool.name"], "run_terminal_command");
  assert.equal(tool.attributes["crok.tool.outcome"], "error");
  assert.equal(tool.attributes["crok.tool.exit_code"], 1);
  assert.equal(tool.attributes["agento11y.tag.branch"], "charlie/dev");
  assert.equal(tool.status.code, 2);
  assert.equal(hrTimeToMilliseconds(tool.startTime), t0 + 3_100);
  assert.equal(hrTimeToMilliseconds(tool.endTime), t0 + 5_000);

  // Spans started later, outside any turn, get fresh random ids again.
  const other = trace.getTracer("test").startSpan("other");
  other.end();
  assert.notEqual(other.spanContext().traceId, turn.traceId);
});

test("a sub-agent's turn joins the trace of the turn that started it", async () => {
  harness({
    type: "turn",
    span: { traceId: turn.traceId, spanId: "c0ffee0000000001" },
    parent: turn,
    conversationId: "session-10",
    agentName: "crok/explore",
    startedAtMs: t0 + 11_500,
    completedAtMs: t0 + 30_800,
    error: "the model stopped answering",
  });
  await flushOtel(otel);
  const sub = spans.getFinishedSpans().find((s) => s.name === "invoke_agent crok/explore");
  assert.ok(sub);
  assert.equal(sub.spanContext().traceId, turn.traceId);
  assert.equal(sub.spanContext().spanId, "c0ffee0000000001");
  assert.equal(sub.parentSpanContext?.spanId, turn.spanId);
  assert.equal(sub.status.code, 2);
});

test("a step becomes a workflow step linked to its generation and turn", async () => {
  harness({
    type: "step",
    id: "step_1",
    parent: turn,
    conversationId: "session-9",
    agentName: "crok",
    stepName: "permission",
    startedAtMs: t0 + 3_050,
    completedAtMs: t0 + 3_052,
    inputState: { tool: "run_terminal_command" },
    outputState: { decision: "allow", source: "rule" },
    linkedGenerationIds: ["gen_turn1"],
  });
  await client.flush();
  const step = steps.find((s) => s.id === "step_1");
  assert.ok(step);
  assert.equal(step.stepName, "permission");
  assert.equal(step.framework, "crok");
  assert.equal(step.traceId, turn.traceId);
  assert.deepEqual(step.outputState, { decision: "allow", source: "rule" });
  assert.deepEqual(step.linkedGenerationIds, ["gen_turn1"]);
});

test("verdicts are exported as scores after the generations, in the scores:export shape", async () => {
  const score: ScoreLine = {
    type: "score",
    scoreId: "crok_abc",
    evaluatorId: "crok.goal_verdict",
    scoreKey: "verdict",
    value: { string: "candidate_complete" },
    passed: true,
    explanation: null,
    generationId: "gen_turn1",
    conversationId: "session-9",
    traceId: turn.traceId,
    spanId: turn.spanId,
  };
  harness(score);
  await deps.scores.flush();
  await settle(deps);
  assert.equal(posted.length, 1);
  assert.equal(posted[0]?.url, "http://127.0.0.1:9/api/v1/scores:export");
  assert.deepEqual(posted[0]?.body, { scores: [wireScore(score, "2.1.0")] });
  const wire = wireScore(score, "2.1.0");
  assert.equal(wire.score_id, "crok_abc");
  assert.equal(wire.evaluator_version, "2.1.0");
  assert.deepEqual(wire.value, { string: "candidate_complete" });
  assert.equal(wire.passed, true);
  assert.equal("explanation" in wire, false);
});

test("harness lines without their required fields are refused", () => {
  assert.ok(parseLine('{"type":"turn","conversationId":"x"}') instanceof Error);
  assert.ok(parseLine('{"type":"score","scoreId":"s","evaluatorId":"e","scoreKey":"k","value":{}}') instanceof Error);
  assert.ok(parseLine('{"type":"guard","phase":"preflight","conversationId":"c","model":{}}') instanceof Error);
});

test("turns, tool runs and steps are counted as metrics with their outcome and origin", async () => {
  await flushOtel(otel);
  const points = (name: string) =>
    metricExporter
      .getMetrics()
      .flatMap((batch) => batch.scopeMetrics)
      .flatMap((scope) => scope.metrics)
      .filter((metric) => metric.descriptor.name === name)
      .flatMap((metric) => metric.dataPoints as { attributes: Record<string, unknown>; value: unknown }[]);
  const turns = points("crok.turns");
  assert.ok(turns.some((p) => p.attributes.outcome === "completed" && p.attributes.origin === "relay" && p.value === 1));
  const tools = points("crok.tool.runs");
  assert.ok(tools.some((p) => p.attributes.tool === "run_terminal_command" && p.attributes.outcome === "error"));
  assert.ok(points("crok.turn.duration").length > 0);
  assert.ok(points("crok.workflow.steps").some((p) => p.attributes.step === "permission" && p.attributes.outcome === "allow"));
});
