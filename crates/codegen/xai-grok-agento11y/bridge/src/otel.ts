// The OpenTelemetry providers the agento11y SDK records into.
// The SDK emits spans and the gen_ai.client.* histograms but creates no providers itself:
// without these two, every span and metric goes to the no-op globals and is lost with no error.

import { randomUUID } from "node:crypto";

import {
  type Attributes,
  type Context,
  type ContextManager,
  context,
  metrics,
  ROOT_CONTEXT,
  trace,
  TraceFlags,
} from "@opentelemetry/api";
import { type ExportResult, ExportResultCode } from "@opentelemetry/core";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-http";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { type Resource, resourceFromAttributes } from "@opentelemetry/resources";
import {
  type AggregationOption,
  type AggregationTemporality,
  type InstrumentType,
  MeterProvider,
  PeriodicExportingMetricReader,
  type PushMetricExporter,
  type ResourceMetrics,
} from "@opentelemetry/sdk-metrics";
import {
  BatchSpanProcessor,
  type IdGenerator,
  RandomIdGenerator,
  type ReadableSpan,
  type Span,
  type SpanExporter,
  type SpanProcessor,
  TracerProvider,
} from "@opentelemetry/sdk-trace";

import type { Log } from "./log.js";

export interface OtelProviders {
  tracerProvider: TracerProvider;
  meterProvider: MeterProvider;
  spanAttributes: CrokSpanAttributes;
  ids: PresetIds;
}

export interface OtelOptions {
  serviceVersion?: string;
  /** How often metrics are pushed; the reader's own default of 60 s is long for a CLI session. */
  metricIntervalMs: number;
  log: Log;
  spanExporter?: SpanExporter;
  metricExporter?: PushMetricExporter;
}

/** Builds both providers, registers them as the OTel globals, and returns them for shutdown. */
export function startOtel(options: OtelOptions): OtelProviders {
  const resource = crokResource(options.serviceVersion);
  // The OTLP exporters read OTEL_EXPORTER_OTLP_ENDPOINT and OTEL_EXPORTER_OTLP_HEADERS themselves.
  const spanExporter = new LoggedSpanExporter(options.spanExporter ?? new OTLPTraceExporter(), options.log);
  const metricExporter = new LoggedMetricExporter(options.metricExporter ?? new OTLPMetricExporter(), options.log);
  const spanAttributes = new CrokSpanAttributes();
  const ids = new PresetIds();
  const tracerProvider = new TracerProvider({
    resource,
    idGenerator: ids,
    spanProcessors: [spanAttributes, new BatchSpanProcessor({ exporter: spanExporter })],
  });
  const meterProvider = new MeterProvider({
    resource,
    readers: [
      new PeriodicExportingMetricReader({
        exporter: metricExporter,
        exportIntervalMillis: options.metricIntervalMs,
      }),
    ],
  });
  trace.setGlobalTracerProvider(tracerProvider);
  metrics.setGlobalMeterProvider(meterProvider);
  context.setGlobalContextManager(new SyncContextManager());
  return { tracerProvider, meterProvider, spanAttributes, ids };
}

/**
 * Span ids crok made. A turn's span is written after its children, which already name its ids
 * (crok makes them when the turn starts), so the next span started takes the preset ids instead
 * of random ones. Everything else gets random ids.
 */
export class PresetIds implements IdGenerator {
  private readonly random = new RandomIdGenerator();
  private traceId: string | undefined;
  private spanId: string | undefined;

  /** Runs `start` with the next span's ids set to these; a span with a parent keeps the parent's trace id. */
  with<T>(traceId: string, spanId: string, start: () => T): T {
    this.traceId = traceId;
    this.spanId = spanId;
    try {
      return start();
    } finally {
      this.traceId = undefined;
      this.spanId = undefined;
    }
  }

  generateTraceId(): string {
    const preset = this.traceId;
    this.traceId = undefined;
    return preset ?? this.random.generateTraceId();
  }

  generateSpanId(): string {
    const preset = this.spanId;
    this.spanId = undefined;
    return preset ?? this.random.generateSpanId();
  }
}

/**
 * The context `context.with` makes active, for code that starts spans synchronously inside it, as
 * the SDK's recorders do. Without a registered manager `context.with` runs its function with the
 * root context, and a generation could not be made a child of its turn.
 */
export class SyncContextManager implements ContextManager {
  private readonly stack: Context[] = [];

  active(): Context {
    return this.stack[this.stack.length - 1] ?? ROOT_CONTEXT;
  }

  with<A extends unknown[], F extends (...args: A) => ReturnType<F>>(
    ctx: Context,
    fn: F,
    thisArg?: ThisParameterType<F>,
    ...args: A
  ): ReturnType<F> {
    this.stack.push(ctx);
    try {
      return fn.call(thisArg, ...args);
    } finally {
      this.stack.pop();
    }
  }

  bind<T>(_ctx: Context, target: T): T {
    return target;
  }

  enable(): this {
    return this;
  }

  disable(): this {
    this.stack.length = 0;
    return this;
  }
}

/** A context whose active span is crok's span `ref` (a turn), for starting its children. */
export function contextOf(ref: { traceId: string; spanId: string } | undefined): Context {
  return ref === undefined
    ? ROOT_CONTEXT
    : trace.setSpanContext(ROOT_CONTEXT, {
        traceId: ref.traceId,
        spanId: ref.spanId,
        traceFlags: TraceFlags.SAMPLED,
        isRemote: true,
      });
}

/**
 * Adds crok's own attributes to a generation's or tool run's span. The SDK fills the span from the
 * record and has no field for others; `onEnding` runs after its last attribute, while the span can
 * still be written, and before the batch processor takes it for export. A generation's span is
 * found by `agento11y.generation.id`, a tool run's by `tool:` and its `gen_ai.tool.call.id`.
 */
export class CrokSpanAttributes implements SpanProcessor {
  private readonly pending = new Map<string, Attributes>();

  /** Attributes for the span of generation `id` (or tool run `tool:<call id>`), written when that span ends. */
  expect(id: string, attributes: Attributes): void {
    this.pending.set(id, attributes);
  }

  /** Drops what no span took (the SDK refused the record before starting one). */
  forget(id: string): void {
    this.pending.delete(id);
  }

  onStart(): void {}

  onEnding(span: Span): void {
    const generation = span.attributes["agento11y.generation.id"];
    const toolCall = span.attributes["gen_ai.tool.call.id"];
    const id =
      typeof generation === "string"
        ? generation
        : typeof toolCall === "string" && span.attributes["gen_ai.operation.name"] === "execute_tool"
          ? `tool:${toolCall}`
          : undefined;
    const attributes = id === undefined ? undefined : this.pending.get(id);
    if (id !== undefined && attributes !== undefined) {
      span.setAttributes(attributes);
      this.pending.delete(id);
    }
  }

  onEnd(): void {}

  forceFlush(): Promise<void> {
    return Promise.resolve();
  }

  shutdown(): Promise<void> {
    this.pending.clear();
    return Promise.resolve();
  }
}

/** Pushes whatever spans and metrics are buffered now. */
export async function flushOtel(providers: OtelProviders): Promise<void> {
  await Promise.allSettled([providers.tracerProvider.forceFlush(), providers.meterProvider.forceFlush()]);
}

/** Final flush and close; call after the agento11y client has shut down, so its last spans are in. */
export async function shutdownOtel(providers: OtelProviders): Promise<void> {
  await Promise.allSettled([providers.tracerProvider.shutdown(), providers.meterProvider.shutdown()]);
}

function crokResource(serviceVersion: string | undefined): Resource {
  // service.instance.id becomes the `instance` label. Every crok process runs its own bridge
  // (Crok Desktop one per conversation), and without it their cumulative counters would land
  // in the same series and overwrite each other.
  const attributes: Record<string, string> = { "service.name": "crok", "service.instance.id": randomUUID() };
  if (serviceVersion !== undefined && serviceVersion.length > 0) {
    attributes["service.version"] = serviceVersion;
  }
  return resourceFromAttributes(attributes);
}

/** Logs each export's outcome: failures always, successes when AGENTO11Y_DEBUG is on. */
function logExport(log: Log, signal: string, count: number, result: ExportResult): void {
  if (result.code === ExportResultCode.SUCCESS) {
    log.debug(`${signal} export ok (${count})`);
  } else {
    log.warn(`${signal} export failed (${count}): ${result.error?.message ?? "unknown error"}`);
  }
}

class LoggedSpanExporter implements SpanExporter {
  constructor(
    private readonly inner: SpanExporter,
    private readonly log: Log,
  ) {}

  export(spans: ReadableSpan[], resultCallback: (result: ExportResult) => void): void {
    this.inner.export(spans, (result) => {
      logExport(this.log, "traces", spans.length, result);
      resultCallback(result);
    });
  }

  shutdown(): Promise<void> {
    return this.inner.shutdown();
  }

  forceFlush(): Promise<void> {
    return this.inner.forceFlush?.() ?? Promise.resolve();
  }
}

class LoggedMetricExporter implements PushMetricExporter {
  // Forwarded only when the inner exporter has them, so the reader keeps the OTLP
  // exporter's temporality and aggregation choices and falls back to its defaults otherwise.
  readonly selectAggregationTemporality?: (instrumentType: InstrumentType) => AggregationTemporality;
  readonly selectAggregation?: (instrumentType: InstrumentType) => AggregationOption;

  constructor(
    private readonly inner: PushMetricExporter,
    private readonly log: Log,
  ) {
    if (inner.selectAggregationTemporality !== undefined) {
      this.selectAggregationTemporality = inner.selectAggregationTemporality.bind(inner);
    }
    if (inner.selectAggregation !== undefined) {
      this.selectAggregation = inner.selectAggregation.bind(inner);
    }
  }

  export(batch: ResourceMetrics, resultCallback: (result: ExportResult) => void): void {
    const count = batch.scopeMetrics.reduce((sum, scope) => sum + scope.metrics.length, 0);
    this.inner.export(batch, (result) => {
      logExport(this.log, "metrics", count, result);
      resultCallback(result);
    });
  }

  forceFlush(): Promise<void> {
    return this.inner.forceFlush();
  }

  shutdown(): Promise<void> {
    return this.inner.shutdown();
  }
}
