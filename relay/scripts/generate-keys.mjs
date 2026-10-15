#!/usr/bin/env node
// Makes the RSA key pair the relay signs device JWTs with, and writes the four Convex environment variables:
//
//   DEVICE_JWT_PRIVATE_KEY  PKCS#8 PEM (newlines escaped as \n)
//   DEVICE_JWT_KID          key id, in each JWT header
//   DEVICE_JWKS             the public key set, served at /.well-known/jwks.json
//   DEVICE_JWKS_DATA_URI    the same as a data: URI, read by convex/auth.config.ts
//
// Usage:
//   node scripts/generate-keys.mjs              writes .env.device-keys (git-ignored) and prints the next command
//   node scripts/generate-keys.mjs --apply      also sets them on the dev deployment (`npx convex env set`)
//   node scripts/generate-keys.mjs --apply --prod   ... on the production deployment
//
// Rotating the key signs every device out within an hour (their JWTs stop verifying); their refresh tokens still work,
// so they get new JWTs on their own.

import { execFileSync } from "node:child_process";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";

const args = new Set(process.argv.slice(2));
const outIndex = process.argv.indexOf("--out");
const outFile = resolve(outIndex > 0 ? process.argv[outIndex + 1] : ".env.device-keys");

const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const kid = `crok-${new Date().toISOString().slice(0, 10)}-${randomBytes(4).toString("hex")}`;
const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
const jwk = { ...publicKey.export({ format: "jwk" }), kid, alg: "RS256", use: "sig" };
const jwks = JSON.stringify({ keys: [jwk] });
const dataUri = `data:text/plain;charset=utf-8;base64,${Buffer.from(jwks).toString("base64")}`;

const quote = (value) => `"${value.replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/"/g, '\\"')}"`;
const lines = [
  `DEVICE_JWT_PRIVATE_KEY=${quote(pem.trim())}`,
  `DEVICE_JWT_KID=${kid}`,
  `DEVICE_JWKS=${quote(jwks)}`,
  `DEVICE_JWKS_DATA_URI=${dataUri}`,
];
writeFileSync(outFile, `${lines.join("\n")}\n`, { mode: 0o600 });
console.log(`Wrote ${outFile} (key id ${kid}). Keep it secret; it is git-ignored.`);

const setArgs = ["convex", "env", "set", "--from-file", outFile, "--force"];
if (args.has("--prod")) setArgs.push("--prod");
if (args.has("--apply")) {
  execFileSync("npx", setArgs, { stdio: "inherit" });
  console.log("Set on the deployment. Push the functions again (npx convex dev / deploy) so auth.config.ts picks up the key.");
} else {
  console.log(`Next: npx ${setArgs.join(" ")}`);
}
