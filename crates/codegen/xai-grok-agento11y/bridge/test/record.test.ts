// Feeds bridge lines through the real SDK client and real OTel providers (in-memory exporters)
// and checks all three outputs: the generation export payload, the span, and the metrics.

import assert from "node:assert/strict";
import { test } from "node:test";

import { Agento11yClient, type Generation } from "@grafana/agento11y-core";
import { hrTimeToMilliseconds } from "@opentelemetry/core";
import { AggregationTemporality, InMemoryMetricExporter } from "@opentelemetry/sdk-metrics";
import { InMemorySpanExporter } from "@opentelemetry/sdk-trace";

import type { Log } from "../src/log.js";
import { flushOtel, startOtel } from "../src/otel.js";
import { type GenerationLine, parseLine } from "../src/protocol.js";
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
const otel = startOtel({ serviceVersion: "9.9.9", metricIntervalMs: 3_600_000, log, spanExporter: spans, metricExporter });
const exported: Generation[] = [];
const client = new Agento11yClient({
  generationExport: { protocol: "http", endpoint: "http://127.0.0.1:9", auth: { mode: "none" } },
  generationExporter: {
    exportGenerations: async (request) => {
      exported.push(...request.generations);
      return { results: request.generations.map((g) => ({ generationId: g.id, accepted: true })) };
    },
    exportWorkflowSteps: async () => ({ results: [] }),
  },
});

const startedAtMs = Date.UTC(2026, 9, 15, 12, 0, 0);

function turnLine(overrides: Partial<GenerationLine> = {}): GenerationLine {
  return {
    type: "generation",
    start: {
      id: "gen_test1",
      mode: "STREAM",
      model: { provider: "anthropic", name: "claude-sonnet-4-5" },
      startedAtMs,
      conversationId: "session-1",
      conversationTitle: "Fix the flaky test",
      agentName: "crok",
      agentVersion: "1.5.0",
      systemPrompt: "You are crok.",
      maxTokens: 32_000,
      tools: [{ name: "read_file", description: "Read a file", type: "function", inputSchemaJSON: "{}" }],
      tags: { call_kind: "turn" },
      metadata: { "crok.session_id": "session-1" },
    },
    firstTokenAtMs: startedAtMs + 800,
    result: {
      completedAtMs: startedAtMs + 2_500,
      responseId: "msg_123",
      responseModel: "claude-sonnet-4-5-20250929",
      input: [{ role: "user", parts: [{ type: "text", text: "Why does the test fail?" }] }],
      output: [
        {
          role: "assistant",
          parts: [
            { type: "thinking", thinking: "Look at the file first." },
            { type: "text", text: "Reading it." },
            { type: "tool_call", toolCall: { id: "call_1", name: "read_file", inputJSON: '{"path":"a.rs"}' } },
          ],
        },
      ],
      usage: {
        inputTokens: 1_200,
        outputTokens: 80,
        totalTokens: 1_280,
        cacheReadInputTokens: 1_000,
        cacheWriteInputTokens: 150,
        reasoningTokens: 20,
        inputSemantics: "inclusive",
      },
      stopReason: "tool_use",
    },
    ...overrides,
  };
}

async function drain(): Promise<void> {
  await client.flush();
  await flushOtel(otel);
}

test("a finished call becomes a STREAM generation, a span and metrics, all on crok's clock", async () => {
  const error = recordGeneration(client, turnLine());
  assert.equal(error, undefined);
  await drain();

  const generation = exported.find((g) => g.id === "gen_test1");
  assert.ok(generation, "generation exported");
  assert.equal(generation.mode, "STREAM");
  assert.equal(generation.operationName, "streamText");
  assert.equal(generation.conversationId, "session-1");
  assert.equal(generation.conversationTitle, "Fix the flaky test");
  assert.equal(generation.agentName, "crok");
  assert.equal(generation.agentVersion, "1.5.0");
  assert.equal(generation.responseId, "msg_123");
  assert.equal(generation.stopReason, "tool_use");
  assert.equal(generation.usage?.cacheWriteInputTokens, 150);
  assert.equal(generation.usage?.cacheReadInputTokens, 1_000);
  assert.equal(new Date(generation.startedAt).getTime(), startedAtMs);
  assert.equal(new Date(generation.completedAt).getTime(), startedAtMs + 2_500);
  assert.equal(generation.input?.[0]?.role, "user");
  assert.equal(generation.output?.[0]?.parts?.length, 3);
  assert.equal(generation.tags?.call_kind, "turn");

  const span = spans.getFinishedSpans().find((s) => s.attributes["agento11y.generation.id"] === "gen_test1");
  assert.ok(span, "span exported");
  assert.equal(span.attributes["gen_ai.operation.name"], "streamText");
  assert.equal(span.attributes["gen_ai.conversation.id"], "session-1");
  assert.equal(span.attributes["gen_ai.agent.version"], "1.5.0");
  assert.equal(span.attributes["gen_ai.provider.name"], "anthropic");
  assert.equal(span.attributes["gen_ai.usage.cache_write_input_tokens"], 150);
  assert.equal(hrTimeToMilliseconds(span.startTime), startedAtMs);
  assert.equal(hrTimeToMilliseconds(span.endTime), startedAtMs + 2_500);
  assert.equal(span.resource.attributes["service.name"], "crok");
  assert.equal(span.resource.attributes["service.version"], "9.9.9");
  assert.match(String(span.resource.attributes["service.instance.id"]), /^[0-9a-f-]{36}$/);

  const names = new Set(
    metricExporter
      .getMetrics()
      .flatMap((batch) => batch.scopeMetrics)
      .flatMap((scope) => scope.metrics)
      .map((metric) => metric.descriptor.name),
  );
  assert.ok(names.has("gen_ai.client.operation.duration"), [...names].join(","));
  assert.ok(names.has("gen_ai.client.token.usage"));
  assert.ok(names.has("gen_ai.client.time_to_first_token"));
  assert.ok(logged.some((line) => line.startsWith("DEBUG traces export ok")));
  assert.ok(logged.some((line) => line.startsWith("DEBUG metrics export ok")));
});

test("a failed call keeps its input and is filed under the HTTP status's error category", async () => {
  const line = turnLine({ error: { message: "rate limited by the provider", statusCode: 429 } });
  line.start.id = "gen_test2";
  line.result = { completedAtMs: startedAtMs + 300, input: line.result.input };
  delete line.firstTokenAtMs;
  assert.equal(recordGeneration(client, line), undefined);
  await drain();

  const generation = exported.find((g) => g.id === "gen_test2");
  assert.ok(generation);
  assert.equal(generation.callError, "HTTP 429: rate limited by the provider");
  assert.equal(generation.input?.length, 1);
  const span = spans.getFinishedSpans().find((s) => s.attributes["agento11y.generation.id"] === "gen_test2");
  assert.ok(span);
  assert.equal(span.attributes["error.category"], "rate_limit");
});

test("parseLine accepts generation and flush lines and rejects the rest", () => {
  assert.equal(parseLine("   "), undefined);
  assert.deepEqual(parseLine('{"type":"flush"}'), { type: "flush" });
  assert.ok(parseLine("{not json") instanceof Error);
  assert.ok(parseLine('{"type":"other"}') instanceof Error);
  assert.ok(parseLine('{"type":"generation","start":{"id":"x"}}') instanceof Error);
  const parsed = parseLine(JSON.stringify(turnLine()));
  assert.ok(parsed !== undefined && !(parsed instanceof Error) && parsed.type === "generation");
});
