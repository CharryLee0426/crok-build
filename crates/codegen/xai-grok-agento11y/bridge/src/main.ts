// crok's Agent Observability bridge.
//
// crok (Rust) starts this with `node agento11y-bridge.mjs` the first time a session makes a
// model call, and writes one JSON line per finished call to its stdin (see protocol.ts).
// The bridge records each call with the agento11y TypeScript SDK: the generation goes to the
// Agent Observability ingest API (AGENTO11Y_*), and the SDK's spans and gen_ai.client.* metrics
// go over OTLP (OTEL_EXPORTER_OTLP_*). When crok closes stdin (it exits, or the bridge sat idle)
// the bridge flushes everything and exits.

import { createInterface } from "node:readline";

import { Agento11yClient, createSecretRedactionSanitizer, SDK_VERSION } from "@grafana/agento11y-core";

import { describe, sdkLogger, stderrLog } from "./log.js";
import { flushOtel, shutdownOtel, startOtel } from "./otel.js";
import { parseLine } from "./protocol.js";
import { recordGeneration } from "./record.js";

/** The SDK's final flush waits up to its 30 s request timeout; this leaves room for the OTLP flush after it. */
const SHUTDOWN_DEADLINE_MS = 45_000;

const env = process.env;
const log = stderrLog(isOn(env.AGENTO11Y_DEBUG));
const otel = startOtel({
  serviceVersion: env.AGENTO11Y_AGENT_VERSION,
  metricIntervalMs: positiveInt(env.CROK_AGENTO11Y_METRIC_INTERVAL_MS) ?? 15_000,
  log,
});
// Built with no export settings: the SDK reads AGENTO11Y_ENDPOINT, _PROTOCOL, _AUTH_MODE,
// _AUTH_TENANT_ID, _AUTH_TOKEN, _AGENT_NAME, _AGENT_VERSION, _TAGS and _CONTENT_CAPTURE_MODE itself.
const client = new Agento11yClient({
  logger: sdkLogger(log),
  // Coding sessions read .env files and print keys; the SDK's redactor keeps known secret
  // formats out of exported text. CROK_AGENTO11Y_REDACT_SECRETS=false turns it off.
  generationSanitizer: isOff(env.CROK_AGENTO11Y_REDACT_SECRETS) ? undefined : createSecretRedactionSanitizer(),
});

let recorded = 0;
let rejected = 0;
let shuttingDown = false;

log.info(
  `started: pid ${process.pid}, node ${process.version}, agento11y-core ${SDK_VERSION}, ` +
    `generations to ${env.AGENTO11Y_ENDPOINT ?? "(unset)"}, otlp to ${env.OTEL_EXPORTER_OTLP_ENDPOINT ?? "(unset)"}`,
);

const lines = createInterface({ input: process.stdin, crlfDelay: Number.POSITIVE_INFINITY, terminal: false });
lines.on("line", (text) => {
  const line = parseLine(text);
  if (line === undefined) {
    return;
  }
  if (line instanceof Error) {
    log.warn(`skipped a line: ${line.message}`);
    return;
  }
  if (line.type === "flush") {
    void flush();
    return;
  }
  try {
    const error = recordGeneration(client, line);
    if (error === undefined) {
      recorded += 1;
      log.debug(`recorded ${line.start.id} (${line.start.agentName ?? "agent?"}, ${line.start.model.name})`);
    } else {
      rejected += 1;
      log.warn(`${line.start.id} not recorded: ${error.message}`);
    }
  } catch (error) {
    rejected += 1;
    log.warn(`${line.start.id} not recorded: ${describe(error)}`);
  }
});
lines.on("close", () => void shutdown("stdin closed"));

for (const signal of ["SIGTERM", "SIGHUP", "SIGINT"] as const) {
  process.on(signal, () => void shutdown(signal));
}
process.on("uncaughtException", (error) => {
  log.error(`uncaught: ${error.stack ?? error.message}`);
  void shutdown("uncaught exception");
});
process.on("unhandledRejection", (reason) => log.error(`unhandled rejection: ${describe(reason)}`));

async function flush(): Promise<void> {
  try {
    await client.flush();
  } catch (error) {
    log.warn(`flush: ${describe(error)}`);
  }
  await flushOtel(otel);
  log.debug("flushed");
}

async function shutdown(reason: string): Promise<void> {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  log.info(`stopping (${reason}): ${recorded} recorded, ${rejected} rejected`);
  const deadline = setTimeout(() => {
    log.warn("stop deadline passed, exiting with exports still pending");
    process.exit(1);
  }, SHUTDOWN_DEADLINE_MS);
  try {
    await client.shutdown();
  } catch (error) {
    log.warn(`agento11y shutdown: ${describe(error)}`);
  }
  // After the client, so the spans of its last generations are in the batch.
  await shutdownOtel(otel);
  clearTimeout(deadline);
  log.info("stopped");
  process.exit(0);
}

function isOn(value: string | undefined): boolean {
  return value !== undefined && ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function isOff(value: string | undefined): boolean {
  return value !== undefined && ["0", "false", "no", "off"].includes(value.trim().toLowerCase());
}

function positiveInt(value: string | undefined): number | undefined {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}
