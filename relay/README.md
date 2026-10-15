# Crok remote control: relay and web app

Follow and steer the crok sessions on your computers from a phone or a browser. This folder is the hub:

- `convex/` — the relay backend (Convex: realtime database, functions, device sign-in, crons).
- `app/` — the web app (Next.js, hosted on Vercel, sign-in with Clerk via GitHub or Google). It is also where
  computers and phones are approved when they sign in.
- `DESIGN.md` — how it all fits together: identity, data model, the API every client uses, the computer-side bridge,
  and the phone apps' Telegram-derived design.

The other pieces live elsewhere in the repo: the computer side in `crates/codegen/crok-remote` and
`crates/codegen/xai-grok-shell/src/remote_control` (used by the `crok` TUI and Crok Desktop), and the phone apps in
`mobile/iOS` and `mobile/Android`.

## 1. Convex

```sh
cd relay
npm install
npx convex dev            # first run: log in (or choose "local"), create the project; leaves the dev deployment running
```

Generate the key the relay signs device tokens with, and put it on the deployment:

```sh
npm run keys -- --apply           # dev deployment
npm run keys -- --apply --prod    # production deployment (after the first `npx convex deploy`)
```

`scripts/generate-keys.mjs` writes `.env.device-keys` (git-ignored; keep it secret) and sets `DEVICE_JWT_PRIVATE_KEY`,
`DEVICE_JWT_KID`, `DEVICE_JWKS` and `DEVICE_JWKS_DATA_URI`. Rotating it later only makes devices fetch a new token.

Set the other environment variables (`npx convex env set NAME value`, add `--prod` for production):

| variable | value |
|---|---|
| `CLERK_JWT_ISSUER_DOMAIN` | your Clerk Frontend API URL, e.g. `https://verb-noun-00.clerk.accounts.dev` (dev) or `https://clerk.your-domain.com` (prod) |
| `CROK_WEB_URL` | where the web app is served, e.g. `https://crok.your-domain.com` — sign-in codes link to `<CROK_WEB_URL>/link?code=…` |

## 2. Clerk (GitHub and Google)

1. Create an application at [dashboard.clerk.com](https://dashboard.clerk.com).
2. **Social connections**: User & Authentication → SSO connections → add **GitHub** and **Google** ("For all users").
   Development instances work with Clerk's shared credentials. For production, turn on "Use custom credentials" and
   create a GitHub OAuth App and a Google OAuth client (type *Web application*) with the callback URL Clerk shows; set
   the Google app to *In production*.
3. **Convex integration**: Clerk dashboard → Integrations → Convex → activate. It adds `aud: "convex"` to session
   tokens. Copy the Frontend API URL into `CLERK_JWT_ISSUER_DOMAIN` above.
4. Note the publishable key (`pk_…`) and secret key (`sk_…`) for the web app.

A Clerk production instance needs your own domain (not `*.vercel.app`).

## 3. Web app on Vercel

Import the repository on Vercel with **Root Directory** `relay`. `vercel.json` sets the build command to
`npx convex deploy --cmd 'npm run build'`, which pushes the Convex functions and then builds Next.js with
`NEXT_PUBLIC_CONVEX_URL` filled in.

Environment variables on Vercel:

| variable | value |
|---|---|
| `CONVEX_DEPLOY_KEY` | Convex dashboard → Settings → Deploy keys → *production* key (Production env only) |
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | `pk_…` |
| `CLERK_SECRET_KEY` | `sk_…` |
| `NEXT_PUBLIC_CLERK_SIGN_IN_URL` | `/sign-in` |

Then set `CROK_WEB_URL` on the Convex production deployment to the site's address.

Local web development: `npx convex dev` in one terminal, `npm run dev` in another (with the Clerk keys in
`.env.local`).

## 4. Signing devices in

Every device signs in the same way: it shows a short code, you approve it on the web (signed in with GitHub or
Google), and the device keeps a refresh token. No token travels in a URL. Approve only a sign-in you just started.

**A computer (optional):**

```sh
crok remote login --server https://<deployment>.convex.cloud   # prints a code and a QR code, opens the browser
crok remote status
crok remote logout
```

`--server` is remembered as `[remote] url` in `~/.crok/config.toml`. In the TUI, `/remote`, `/remote login`,
`/remote logout`, `/remote on|off`; in Crok Desktop, Settings › Remote control. While signed in, every crok process
(the TUI, each Crok Desktop task) mirrors its sessions; `[remote] enabled = false` stops that without signing out.

**A phone (required to use the app):** open the Crok app, *Continue with GitHub or Google*, and approve. A signed-in
phone can also link a computer by scanning the QR code `crok remote login` prints (Settings › Link a computer).

## 5. Checking it locally

```sh
cd relay
CONVEX_AGENT_MODE=anonymous npx convex dev      # local backend at http://127.0.0.1:3210, no account needed
npm run keys -- --apply
npx convex env set CLERK_JWT_ISSUER_DOMAIN https://placeholder.clerk.accounts.dev   # any value for the scripts
npm run test:e2e                                # the relay alone: sign-in, mirroring, commands, revocation
CROK_BIN=…/xai-grok-pager CROK_HOME=/tmp/crok-e2e E2E_PROJECT=/tmp/project node scripts/bridge-e2e.mjs
```

For the phone apps against a local relay: the iOS simulator reaches the Mac as `127.0.0.1`, the Android emulator as
`10.0.2.2` (so build Android with `-PcrokRelayUrl=http://10.0.2.2:3210`, and set
`npx convex env set CROK_WEB_URL http://10.0.2.2:3000` while testing from the emulator so its sign-in sheet can load the
approval page). `node scripts/phone-sim.mjs` is a pretend phone for the terminal (`link`, `list`, `send`, `stop`,
`info`), and `node scripts/fake-computer.mjs` a pretend computer with one session that answers prompts, Stop and info,
for trying the apps and the web app without running crok.

The agent needs a model: `python3 scripts/mock-llm.py 18765` serves an OpenAI-compatible one that streams canned
replies (slowly when the prompt says "slow"); point `CROK_HOME/config.toml` at it:

```toml
[models]
default = "smoke-model"

[model.smoke-model]
model = "smoke-model"
base_url = "http://127.0.0.1:18765/v1"
name = "Smoke Model"
api_key = "sk-test"
api_backend = "chat_completions"
context_window = 128000
```

`scripts/tui-e2e.py` does the same for the TUI in a pseudo-terminal (`/remote login`, the footer link, a phone prompt
shown in the TUI, `/remote`, offline on quit).

`bridge-e2e.mjs` signs a real `crok` in with `crok remote login`, runs a `crok agent stdio` (what Crok Desktop runs per
task) against a model you point `CROK_HOME/config.toml` at, and plays the phone: reads the transcript, sends a prompt,
asks for session info, stops a running turn, and checks the session goes offline when the process exits. The scripts
stand in for the web approval with `npx convex run --identity`.

## Costs and limits

Convex's free plan (0.5 GB storage, 1 GB/month bandwidth) is plenty for one person. Transcript items are capped at
32 000 characters (the computer keeps the full text), and the relay drops a session's copy 30 days after its last
activity. Streaming is fine-grained only while someone has the session open.
