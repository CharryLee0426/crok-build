// The OpenTelemetry providers the agento11y SDK records into.
// The SDK emits spans and the gen_ai.client.* histograms but creates no providers itself:
// without these two, every span and metric goes to the no-op globals and is lost with no error.

import { randomUUID } from "node:crypto";

import { type Attributes, metrics, trace } from "@opentelemetry/api";
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
  const tracerProvider = new TracerProvider({
    resource,
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
  return { tracerProvider, meterProvider, spanAttributes };
}

/**
 * Adds crok's own attributes to a generation's span. The SDK fills the span from the generation
 * and has no field for others; `onEnding` runs after its last attribute, while the span can still
 * be written, and before the batch processor takes it for export.
 */
export class CrokSpanAttributes implements SpanProcessor {
  private readonly pending = new Map<string, Attributes>();

  /** Attributes for the span of generation `id`, written when that span ends. */
  expect(id: string, attributes: Attributes): void {
    this.pending.set(id, attributes);
  }

  /** Drops what no span took (the SDK refused the generation before starting one). */
  forget(id: string): void {
    this.pending.delete(id);
  }

  onStart(): void {}

  onEnding(span: Span): void {
    const id = span.attributes["agento11y.generation.id"];
    const attributes = typeof id === "string" ? this.pending.get(id) : undefined;
    if (attributes !== undefined) {
      span.setAttributes(attributes);
      this.pending.delete(id as string);
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
