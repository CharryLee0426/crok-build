import type { Agento11yLogger } from "@grafana/agento11y-core";

/** The bridge's log. crok points the bridge's stderr at ~/.crok/logs/agento11y.log. */
export interface Log {
  debug(message: string): void;
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

export function stderrLog(debugEnabled: boolean): Log {
  const write = (level: string, message: string) => {
    process.stderr.write(`${new Date().toISOString()} ${level} ${message}\n`);
  };
  return {
    debug: (message) => {
      if (debugEnabled) {
        write("DEBUG", message);
      }
    },
    info: (message) => write("INFO", message),
    warn: (message) => write("WARN", message),
    error: (message) => write("ERROR", message),
  };
}

/** Routes the SDK's own warnings (rejected exports, invalid env values) into the bridge log. */
export function sdkLogger(log: Log): Agento11yLogger {
  const join = (message: string, args: unknown[]) =>
    [message, ...args.map(describe)].filter((part) => part.length > 0).join(" ");
  return {
    debug: (message, ...args) => log.debug(`sdk: ${join(message, args)}`),
    warn: (message, ...args) => log.warn(`sdk: ${join(message, args)}`),
    error: (message, ...args) => log.error(`sdk: ${join(message, args)}`),
  };
}

export function describe(value: unknown): string {
  if (value instanceof Error) {
    return value.message;
  }
  if (typeof value === "string") {
    return value;
  }
  try {
    return JSON.stringify(value) ?? String(value);
  } catch {
    return String(value);
  }
}
