import type { Agento11yClient } from "@grafana/agento11y-core";

import { type GenerationLine, toCallError, toResult, toStart } from "./protocol.js";

/**
 * Records one finished model call through the SDK recorder, the same way a provider
 * wrapper would around a live call, but with crok's timestamps.
 * Returns the recorder's own error (validation or enqueue), which the SDK otherwise keeps silent.
 */
export function recordGeneration(client: Agento11yClient, line: GenerationLine): Error | undefined {
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
  }
  return recorder.getError();
}
