import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";

const http = httpRouter();

/** The public half of the device JWT key, for `auth.config.ts` when `DEVICE_JWKS_DATA_URI` is not set. */
http.route({
  path: "/.well-known/jwks.json",
  method: "GET",
  handler: httpAction(async () => {
    const jwks = process.env.DEVICE_JWKS;
    if (!jwks) return new Response("DEVICE_JWKS is not set", { status: 404 });
    return new Response(jwks, {
      status: 200,
      headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" },
    });
  }),
});

http.route({
  path: "/health",
  method: "GET",
  handler: httpAction(async () => new Response("ok", { status: 200 })),
});

export default http;
