/**
 * Device tokens and their JWTs, with Web Crypto only. Everything here is allowed in Convex queries and mutations:
 * `getRandomValues` is seeded per execution (unpredictable to clients), `digest` and RSASSA-PKCS1-v1_5 `sign` need no
 * randomness.
 */

/** Device JWT audience; `auth.config.ts` names the same value as the custom JWT provider's `applicationID`. */
export const DEVICE_AUDIENCE = "crok-device";

/** One hour. Clients refresh a few minutes before it runs out and on every reconnect. */
export const ACCESS_TOKEN_TTL_MS = 60 * 60 * 1000;

/** Consonants only, as RFC 8628 suggests: no vowels (no words), nothing that reads as another character. */
const USER_CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ";

export function randomBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return bytes;
}

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlText(text: string): string {
  return base64url(new TextEncoder().encode(text));
}

/** A secret only the device keeps: 256 bits, with a readable prefix so a leaked one is recognisable. */
export function newSecret(prefix: string): string {
  return `${prefix}_${base64url(randomBytes(32))}`;
}

/** `XXXX-XXXX` from the consonant alphabet: 20^8 ≈ 2.6e10 codes, each alive for ten minutes. */
export function newUserCode(): string {
  const bytes = randomBytes(8);
  let code = "";
  for (let i = 0; i < 8; i++) {
    code += USER_CODE_ALPHABET[bytes[i] % USER_CODE_ALPHABET.length];
    if (i === 3) code += "-";
  }
  return code;
}

/** Upper-cases and restores the dash, so `bcdf ghjk`, `BCDFGHJK` and `BCDF-GHJK` all match. */
export function normalizeUserCode(input: string): string {
  const letters = input.toUpperCase().replace(/[^A-Z]/g, "");
  if (letters.length !== 8) return letters;
  return `${letters.slice(0, 4)}-${letters.slice(4)}`;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function pemToDer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) der[i] = binary.charCodeAt(i);
  return der.buffer;
}

export function deviceIssuer(): string {
  const issuer = process.env.CONVEX_SITE_URL;
  if (!issuer) throw new Error("CONVEX_SITE_URL is not set on this deployment");
  return issuer.replace(/\/+$/, "");
}

/**
 * Signs a one-hour RS256 JWT whose subject is the device id. Convex checks it against the custom JWT provider in
 * `auth.config.ts` (issuer = this deployment's site URL, audience `crok-device`, key `DEVICE_JWT_KID`).
 */
export async function signDeviceJwt(deviceId: string, now: number): Promise<{ token: string; expiresAt: number }> {
  const pem = process.env.DEVICE_JWT_PRIVATE_KEY;
  const kid = process.env.DEVICE_JWT_KID;
  if (!pem || !kid) {
    throw new Error("DEVICE_JWT_PRIVATE_KEY and DEVICE_JWT_KID are not set; run `npm run keys` (see relay/README.md)");
  }
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const iat = Math.floor(now / 1000);
  const expiresAt = now + ACCESS_TOKEN_TTL_MS;
  const header = { alg: "RS256", typ: "JWT", kid };
  const payload = {
    iss: deviceIssuer(),
    sub: deviceId,
    aud: DEVICE_AUDIENCE,
    iat,
    exp: Math.floor(expiresAt / 1000),
  };
  const signingInput = `${base64urlText(JSON.stringify(header))}.${base64urlText(JSON.stringify(payload))}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return { token: `${signingInput}.${base64url(new Uint8Array(signature))}`, expiresAt };
}
