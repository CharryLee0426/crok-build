import type { AuthConfig } from "convex/server";

/**
 * Two kinds of caller:
 *
 * - People on the web app, signed in with Clerk (GitHub or Google). Set `CLERK_JWT_ISSUER_DOMAIN` to the Clerk
 *   Frontend API URL (Clerk dashboard → Convex integration).
 * - Linked devices (crok on a computer, the phone apps), with one-hour RS256 JWTs this deployment signs itself
 *   (`convex/lib/crypto.ts`). The public key set comes from `DEVICE_JWKS_DATA_URI` (written by `npm run keys`), or
 *   else from this deployment's own `/.well-known/jwks.json` route.
 */
const providers: AuthConfig["providers"] = [];

if (process.env.CLERK_JWT_ISSUER_DOMAIN) {
  providers.push({ domain: process.env.CLERK_JWT_ISSUER_DOMAIN, applicationID: "convex" });
}

const siteUrl = (process.env.CONVEX_SITE_URL ?? "").replace(/\/+$/, "");
providers.push({
  type: "customJwt",
  applicationID: "crok-device",
  issuer: siteUrl,
  jwks: process.env.DEVICE_JWKS_DATA_URI ?? `${siteUrl}/.well-known/jwks.json`,
  algorithm: "RS256",
});

export default { providers } satisfies AuthConfig;
