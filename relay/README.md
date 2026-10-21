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

## Two environments

The relay runs twice, and every client is built for exactly one of them. `environments/prod.env` and
`environments/dev.env` say where each one is; crok's build, the phone builds and the scripts below read them.

| | **prod** | **test** (dev relay) |
|---|---|---|
| Convex | production deployment `tacit-finch-29` | development deployment `limitless-badger-727` |
| Clerk | "Crok Remote" production instance, `clerk.crok.chenli.dev` | its development instance, `glorious-skunk-713.clerk.accounts.dev` |
| Web | Vercel `crok-relay-prod`, https://crok.chenli.dev | Vercel `crok-relay`, https://crok-relay.vercel.app |
| crok, Crok Desktop | releases and every build not marked as a test: `make build`, `make deploy`, `make dmg-desktop`, `release/publish.sh` | `make build-test-tui` / `build-test-desktop` (crok-test, Crok Desktop Test), or `CROK_RELAY_ENV=dev` |
| Phones | `mobile/scripts/build-apps.sh prod`: iOS Release + Android release, `*-prod` in `~/Desktop/Crok mobile e2e builds` | `mobile/scripts/build-apps.sh test`: iOS Debug + Android debug, `*-debug` there |
| Functions + web | `scripts/deploy.sh prod` | `scripts/deploy.sh test` |

`make clients-prod` / `make clients-test` run the deploy and the phone builds together. crok picks the relay at build
time (`CROK_RELAY_ENV`, default `prod`; `crok version --json` shows it under `remote`), and keeps each environment's
sign-in in its own file (`~/.crok/remote/credentials.json` for prod, `credentials-dev.json` for test builds), so the
release and the test build on one Mac stay signed in side by side. A build that finds a sign-in to the other relay
does not use it: crok moves it to that environment's file, the phone apps sign out and ask again.

`scripts/deploy.sh` pushes the functions from the commit checked out (`--working-tree` for uncommitted changes) with
the deployment's `CROK_WEB_URL` and `CLERK_JWT_ISSUER_DOMAIN` set from the environment file and a device signing key
made if there is none, then deploys the web from a copy outside the repository (the Vercel CLI sends a checkout's
commit metadata, and the Hobby plan refuses co-authored commits as "Not authorized"). Before deploying it checks the
Vercel project's Production variables: `NEXT_PUBLIC_CONVEX_URL` must be the environment's deployment and
`NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` a `pk_live_` key for prod, `pk_test_` for test, with `CLERK_SECRET_KEY` beside it.
`scripts/vercel-keys.sh prod|test` puts them there straight from `clerk env pull` (and, for prod, a Convex deploy key
as `CONVEX_DEPLOY_KEY`) without printing them; run it after `clerk deploy` or a key rotation, then deploy the web.

Both Vercel projects are connected to this repository with Root Directory `relay`. `crok-relay-prod` builds only
production deployments (its Ignored Build Step skips previews, which Clerk production keys would refuse anyway), so
merging into `main` redeploys https://crok.chenli.dev; its build pushes the functions too when the project has a
production `CONVEX_DEPLOY_KEY`.

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

Import the repository on Vercel with **Root Directory** `relay` (Settings → Build and Deployment). Pushes then
deploy on their own: the production branch (`main`) updates the site and every other branch, pull requests included,
gets a preview. A project left at the root fails every Git build with `sh: scripts/vercel-build.sh: No such file or
directory`. To deploy by hand, run the CLI from the **repository root**, not this folder (with Root Directory `relay`
the CLI looks for `relay/relay` there): `vercel link --project <name>`, then `vercel deploy` or `vercel deploy --prod`.
The root `.vercelignore` uploads `relay/` alone, without `.env*`, the device key and local state. `vercel.json` runs
`scripts/vercel-build.sh`:

- with `CONVEX_DEPLOY_KEY` set, it runs `npx convex deploy --cmd 'npm run build'`: the Convex functions go to that
  deployment and the site is built against it;
- without one, it only builds the site against `NEXT_PUBLIC_CONVEX_URL` — for a site in front of a **dev**
  deployment, whose functions you push with `npx convex dev`.

Environment variables on Vercel, for **Production and Preview** (a preview build without them stops at the check in
`scripts/vercel-build.sh`; a site in front of a dev deployment can give previews the same dev Convex deployment and
dev Clerk instance):

| variable | value |
|---|---|
| `CONVEX_DEPLOY_KEY` | Convex dashboard → Settings → Deploy keys → *production* key (Production env only); or leave it out and set `NEXT_PUBLIC_CONVEX_URL` |
| `NEXT_PUBLIC_CONVEX_URL` | only without a deploy key: the dev deployment, `https://<name>.convex.cloud` |
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | `pk_…` (`clerk env pull` prints both keys) |
| `CLERK_SECRET_KEY` | `sk_…` |

Then set `CROK_WEB_URL` on the Convex deployment to the site's address.

With the Clerk CLI: `clerk apps create "Crok Remote"`, `clerk link --app <id>`, enable GitHub with
`clerk config patch --json '{"connection_oauth_github":{"enabled":true}}'` (Google is on by default), and create the
`convex` JWT template with `clerk api /jwt_templates -d '{"name":"convex","claims":{"aud":"convex","name":"{{user.full_name}}","email":"{{user.primary_email_address}}","picture":"{{user.image_url}}"}}'`.

Local web development: `npx convex dev` in one terminal, `npm run dev` in another (with the Clerk keys in
`.env.local`).

## 4. Signing devices in

Every device signs in the same way: it shows a short code, you approve it on the web (signed in with GitHub or
Google), and the device keeps a refresh token. No token travels in a URL. Approve only a sign-in you just started.

**A computer (optional):**

```sh
crok remote login    # prints a code and a QR code, opens the browser
crok remote status
crok remote logout
```

The relay's address is built into crok (`CROK_REMOTE_DEFAULT_URL` at build time picks another; for a local relay,
`CROK_REMOTE_URL=http://127.0.0.1:3210` or `[remote] url` at run time). In the TUI, `/remote`, `/remote login`,
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
node scripts/commands-e2e.mjs                   # new sessions from any device, model / thinking level, slash commands
CROK_BIN=…/xai-grok-pager CROK_HOME=/tmp/crok-e2e E2E_PROJECT=~/crok-e2e-project node scripts/bridge-e2e.mjs   # project outside the temp folder
```

Replies render as GitHub-flavoured Markdown with math (DESIGN.md §5 "Replies in Markdown"; `lib/markdown.tsx` on
react-markdown, remark-gfm, remark-breaks, highlight.js through rehype-highlight, and KaTeX; `lib/math.ts` finds the
math first, as the phone apps do). `node scripts/markdown-check.mjs` checks it without a browser or a backend: the math
test vectors and `scripts/markdown-showcase.md` rendered to HTML. Under `npm run dev`, `/preview/session-markdown`
(and `-streaming`, replies cut off mid-stream) shows the showcase; add `?theme=dark`.

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

`bridge-e2e.mjs` runs one session while signed out, signs a real `crok` in with `crok remote login`, runs a
`crok agent stdio` (what Crok Desktop runs per task) against a model you point `CROK_HOME/config.toml` at, and plays
the phone: finds the older session listed in the same project (offline), opens it so the running crok reads its
transcript from disk, reads the live transcript, sends a prompt, asks for session info, stops a running turn, and checks
the session goes offline when the process exits. The scripts
stand in for the web approval with `npx convex run --identity`.

## Costs and limits

Convex's free plan (0.5 GB storage, 1 GB/month bandwidth) is plenty for one person. Transcript items are capped at
32 000 characters (the computer keeps the full text), and the relay drops a session's transcript 30 days after its
last activity (the session stays listed; opening it reads the transcript from the computer again). Streaming is fine-grained only while someone has the session open.
