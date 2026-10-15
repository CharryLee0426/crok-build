import { ConvexError } from "convex/values";

/** The relay's error codes (DESIGN.md §3). */
export type RelayErrorCode =
  | "UNAUTHENTICATED"
  | "REVOKED"
  | "FORBIDDEN"
  | "NOT_FOUND"
  | "OFFLINE"
  | "INVALID"
  | "EXPIRED"
  | "NOT_CONFIGURED";

export type RelayError = { code: RelayErrorCode | null; message: string };

/** Reads `ConvexError<{ code, message }>`; anything else (argument validation, network) has no code. */
export function relayError(error: unknown): RelayError {
  if (error instanceof ConvexError) {
    const data = error.data as { code?: unknown; message?: unknown } | string | undefined;
    if (data && typeof data === "object") {
      return {
        code: typeof data.code === "string" ? (data.code as RelayErrorCode) : null,
        message: typeof data.message === "string" ? data.message : String(error.message),
      };
    }
    return { code: null, message: typeof data === "string" ? data : error.message };
  }
  if (error instanceof Error) {
    // A malformed id in the URL fails argument validation before any handler runs.
    if (/ArgumentValidationError|Value does not match validator|is not a valid ID/i.test(error.message)) {
      return { code: "NOT_FOUND", message: error.message };
    }
    return { code: null, message: error.message };
  }
  return { code: null, message: String(error) };
}
