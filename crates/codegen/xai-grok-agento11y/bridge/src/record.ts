import type { Agento11yClient } from "@grafana/agento11y-core";
import { context } from "@opentelemetry/api";

import { contextOf, type CrokSpanAttributes } from "./otel.js";
import { type GenerationLine, spanAttributesOf, toCallError, toResult, toStart, validSpanRef } from "./protocol.js";

/**
 * Records one finished model call through the SDK recorder, the same way a provider
 * wrapper would around a live call, but with crok's timestamps.
 * The line's span attributes go on the call's span through `spanAttributes`, and a call made in a
 * turn gets the turn's span as its parent.
 * Returns the recorder's own error (validation or enqueue), which the SDK otherwise keeps silent.
 */
export function recordGeneration(
  client: Agento11yClient,
  line: GenerationLine,
  spanAttributes?: CrokSpanAttributes,
): Error | undefined {
  const parent = validSpanRef(line.parent);
  if (parent === undefined) {
    return recordGenerationHere(client, line, spanAttributes);
  }
  return context.with(contextOf(parent), () => recordGenerationHere(client, line, spanAttributes));
}

function recordGenerationHere(
  client: Agento11yClient,
  line: GenerationLine,
  spanAttributes?: CrokSpanAttributes,
): Error | undefined {
  const extra = spanAttributesOf(line);
  if (extra !== undefined) {
    spanAttributes?.expect(line.start.id, extra);
  }
  const start = toStart(line.start);
  const recorder =
    line.start.mode === "SYNC" ? client.startGeneration(start) : client.startStreamingGeneration(start);
  try {
    if (typeof line.firstTokenAtMs === "number") {
      recorder.setFirstTokenAt(new Date(line.firstTokenAtMs));
    }
    recorder.setResult(toResult(line.result));
    if (line.error !== undefined) {
      recorder.setCallError(toCallError(line.error));
    }
  } finally {
    recorder.end();
    spanAttributes?.forget(line.start.id);
  }
  return recorder.getError();
}
