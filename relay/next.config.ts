import { readFileSync } from "node:fs";
import type { NextConfig } from "next";
import { PHASE_DEVELOPMENT_SERVER } from "next/constants";
import pkg from "./package.json";

/**
 * Profile › Version: the crok release this relay ships with and the commit, fixed at build time. Vercel builds only
 * relay/, so scripts/deploy.sh passes them (`CROK_WEB_RELEASE`, `CROK_WEB_COMMIT`); a local build reads ../VERSION.
 */
function webVersion(): string {
  let release = process.env.CROK_WEB_RELEASE?.trim() || null;
  if (!release) {
    try {
      release = readFileSync("../VERSION", "utf8").trim() || null;
    } catch {
      release = null;
    }
  }
  const commit = (process.env.CROK_WEB_COMMIT ?? process.env.VERCEL_GIT_COMMIT_SHA)?.slice(0, 7) || null;
  return release && commit ? `${release} (${commit})` : (release ?? commit ?? pkg.version);
}

const securityHeaders = [
  // The device approval page must never be framed: that would let another site trick a click on "Approve".
  { key: "Content-Security-Policy", value: "frame-ancestors 'none'" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
];

export default function config(phase: string): NextConfig {
  return {
    poweredByHeader: false,
    devIndicators: false,
    // `next dev` would otherwise (re)write an AGENTS.md into this folder.
    agentRules: false,
    // `*.dev.tsx` routes (the /preview gallery with fake data) exist only under `next dev`; builds never see them.
    pageExtensions: phase === PHASE_DEVELOPMENT_SERVER ? ["dev.tsx", "tsx", "ts"] : ["tsx", "ts"],
    env: { CROK_WEB_VERSION: webVersion() },
    async headers() {
      return [{ source: "/:path*", headers: securityHeaders }];
    },
  };
}
