import type { NextConfig } from "next";
import { PHASE_DEVELOPMENT_SERVER } from "next/constants";

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
    async headers() {
      return [{ source: "/:path*", headers: securityHeaders }];
    },
  };
}
