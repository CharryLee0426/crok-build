> **简体中文 · 日本語 · Español · Français · Deutsch**: translations of these notes follow the English text, under **Translations**.

Crok Desktop 2.0.2 is the native macOS app for this fork. It bundles crok, the agent runtime and the `crok` terminal UI, so there is nothing else to install. It follows 2.0.1, which redesigned both phone apps around computers, projects and topics. In 2.0.2 the browser tool works in the Chrome you already use, signed in as you. Every device can pick the model and thinking level of a session's computer, the web app follows the phone apps' design, and the terminal has a Remote panel. A turn's end now reaches the web and the phones within about a second. Agent Observability follows whole turns, and the release workflow can run an eval suite before it publishes.

This release is built and published by GitHub Actions, as soon as its pull request merged, as 2.0.1 was.

## Install

1. Download the disk image that matches your macOS version and open it. The table under **Which disk image to download** says which one.
2. Drag **Crok Desktop** onto **Applications**.
3. Open Crok Desktop from Applications. This build is not notarized, so the first time macOS says it cannot verify the app: click **Done**, open **System Settings › Privacy & Security**, click **Open Anyway** beside the Crok Desktop message, and confirm. You only do this once.
4. Sign in from **Settings › Accounts** with OpenRouter, OpenAI Codex, an Anthropic API key, a DeepSeek API key or a GLM Coding Plan key.

Requires macOS 14 Sonoma or later on Apple silicon (M1 or later).

## Which disk image to download

Both images are Crok Desktop 2.0.2 and contain the same features. They differ only in the macOS SDK they were built against, which decides whether the window chrome uses Apple's Liquid Glass:

| Disk image | Built against | Use it on | Title bar |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.2-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 and later | Liquid Glass |
| `Crok-Desktop-2.0.2-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 and 15 | Frosted blur within the window |

On macOS 26 and later, prefer the macOS 26 SDK image for the Liquid Glass title bar. On macOS 14 or 15, take the macOS 15 SDK image. It also runs on later versions, so if you are not sure which macOS you have, it is the safe choice.

`crok-2.0.2-aarch64-apple-darwin.tar.gz` is the `crok` terminal UI on its own, for a Mac where you do not want the app: unpack it and put `crok` on your `PATH`. The phone apps are described under **Phone apps**. `SHA256SUMS.txt` lists the SHA-256 of every download, and `SHA256SUMS.txt.sig` is the signature of that list, which the updater checks.

## Phone apps

The Crok app for iPhone and Android follows your computers' sessions, shows their replies and permission requests, and starts or steers tasks from anywhere. It comes with this release as it came with 2.0.1. All three files sign in to the production relay.

- **Android 8.0 or later:** download `Crok-Android-2.0.2.apk` on the phone and open it, allowing your browser to install apps when Android asks, or run `adb install -r Crok-Android-2.0.2.apk`. It is signed with the release key that later releases keep, so the next APK installs over it. A Crok APK you built yourself is signed with another key and blocks the install: remove it first with `adb uninstall dev.chenli.crok.mobile`, or from the phone's settings.
- **iPhone and iPad, iOS 17 or later:** `Crok-iOS-2.0.2-unsigned.ipa` is not signed, because an app for iOS devices is signed with the Apple ID of whoever installs it. Install it with a sideloading tool such as AltStore or Sideloadly, which signs it with your Apple ID. With a free Apple ID, iOS stops opening the app after 7 days until you install it again. To build it yourself instead, use the **Release** configuration: Xcode's Run button builds Debug, which signs in to the test relay.
- **iOS Simulator:** `Crok-iOS-2.0.2-Simulator.zip` unpacks to `Crok.app`, for `xcrun simctl install booted Crok.app` on a Mac with Xcode.

To sign the phone in, tap **Continue with GitHub or Google**, sign in on the page that opens at https://crok.chenli.dev, and tap **Approve**. Then link each computer: run `crok remote login` on it and scan the QR code it shows from the app's **Settings › Link a computer**, or approve the computer on the web page that opens.

## Highlights

- **The browser tool works in your own Chrome.** It opens a window of the browser you already run, on the profile you used last, so the sites you are signed in to stay signed in. It needs a one-time switch in Chrome and your **Allow**: see **Your own browser** below.
- **Pick a session's model and thinking level on every device.** iPhone, Android and the web show two pills above the composer, in new and open sessions: the model, with a sheet that searches and groups models by provider, and the thinking level. A new task in Crok Desktop's **Other computers** offers the same choice before it starts.
- **Computers with hundreds of models offer all of them.** A computer signed in to OpenRouter lists about 480 models. The relay used to refuse any list over 200, so such a computer offered no choice at all; it now keeps up to 1,000.
- **The web app follows the phone apps.** It is laid out like Telegram Web: the selected computer's projects and their topics on the left, the session with its theme in the middle, session info on the right.
- **A Remote panel in the terminal.** `/remote` shows the other computers, their projects and their sessions, as Crok Desktop's **Other computers** does, and `n` starts a session there on a model you pick.
- **A turn's end reaches the web and the phones at once.** After a busy turn they used to show the session working for seconds, sometimes minutes, after the computer had finished. The end now arrives within about a second.
- **Long sessions open quickly on the phones.** The phone apps load a transcript in small live parts, keep a new session's first prompt in sight, and show thinking and tool calls by their status, as Crok Desktop does.
- **OpenRouter's 1M-token models keep working past 105K tokens.** crok asked for an output allowance that left no room for the prompt, which OpenRouter refused once a conversation grew; it now asks for no more output than fits beside the prompt.
- **Agent Observability follows whole turns.** Each turn is one trace with its model calls and tool runs, and the maintainer's stack scores real traffic and checks tool calls that can change something. See **Agent Observability** below.

## Your own browser

The browser tool used to start a browser of its own, with a profile of Crok's. It now opens a window of the Chrome you already run, on the profile you used last, so every site you are signed in to stays signed in. The model is told that the window may be signed in as you.

- **Turn on remote debugging once.** This needs Chrome 144 or later. Open `chrome://inspect/#remote-debugging` in Chrome and turn on **Allow remote debugging for this browser instance**. Chrome refuses a `chrome://` address passed from another app, so Crok Desktop's **Settings › Browser and computer use** has a **Copy Address** button for it.
- **Allow each task once.** When a task first uses the browser, Chrome asks **Allow remote debugging?** Click **Allow**. Crok waits two minutes for the answer and says what to do when remote debugging is off or the question was refused.
- **Your browser stays yours.** Crok never quits it and never takes over its startup tabs, and downloads go where your Chrome settings send them.
- **Crok's own profile is still there.** Choose **Crok's own profile** under **Settings › Browser and computer use › Browser profile** in Crok Desktop, or set `profile = "crok"` under `[toolset.browser]` in `~/.crok/config.toml`. `profile = "user"` is the default.

This was tested with Chrome on macOS. Edge, Brave and Chromium are not tested yet.

## Remote control

Every crok in this release signs in to the production relay at https://crok.chenli.dev, as 2.0.1 does, and keeps the sign-in it already has.

- **Model and thinking level.** In a new session the pills read **Default** until you pick, and the session starts on your choice. In an open session a change goes to its computer, and the pill turns until that computer has applied it; if it refuses, the old value comes back with the reason. Session info shows the same two rows, and the phones' `/model` and `/think` commands read the same list.
- **The web app.** Its left column is a stack of pages: the selected computer's sessions with its projects, a project's topics, archived sessions and the profile. Topics have hover actions and right-click menus for pinning, stopping, marking as read, archiving and reordering. Session themes and the color mode are kept in the browser. Below 1024 pixels wide it shows one column at a time.
- **The terminal's Remote panel.** `/remote` and `/remote open` show the account, this computer and the connection, then a tree of the other computers (online or last seen, with unread counts), their projects and each project's sessions. Enter opens a session as `/resume` does, `n` starts one and asks for that computer's model and thinking level, and typing filters the tree. `/remote status` prints the old text. A session of another computer shows its branch and token figures in the status line, and `/model` there no longer changes this computer's default.
- **Turn ends arrive at once.** The link to the relay now folds the updates waiting behind each write into one, so a busy turn no longer builds a queue that delays its end. A turn that ended shows as ended even when a queued prompt left the queue without running, and a prompt sent from a phone afterwards runs.
- **Phones load long sessions in parts.** The phone apps open a transcript on its newest 40 items and load older ones 60 at a time as you scroll, so a session mirrored for weeks opens quickly on a slow network. A new session's first prompt stays above the composer. Thinking shows as running and then done, and a tool call as running, done, failed or stopped. The relay no longer sends a thought's text or a tool's output to the phones.
- **Update the computers and the phones.** The model lists and the faster turn ends come with crok 2.0.2 on the computer that has the session, and the pickers and the transcript window with the 2.0.2 phone apps. Phone apps from 2.0.1 keep working with the relay.

## Agent Observability

As in 2.0.1, every crok in this release reports each model call it makes to [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) on the maintainer's Grafana Cloud stack, and `crok version --json` shows the host under `agentObservability`. 2.0.2 also reports what happens between the calls:

- **Turns and tool runs.** A turn is one trace whose root span holds its model calls and tool runs, with how the turn ended and how many calls and tool errors it had. A tool run records its outcome, kind, exit code and the size of its result, not its arguments or output. A sub-agent's turn sits under the turn that started it.
- **Steps, verdicts and ratings.** Permission decisions, PreToolUse hook results, compactions and MCP server starts appear as steps on the conversation. crok's own goal evaluator, laziness classifier, repeated-call guard and turn limit report scores, and the ratings you give go there too, as well as to xAI.
- **Tags.** Calls carry `origin` (`local`, `headless` for `crok -p`, `relay` for prompts from the web and phones, `eval` for experiments), and `repo`, `branch` and `user`, the computer's login name.
- **Guard checks, in warn mode.** Before a tool call that can change something runs, and before a tool result goes back to the model, crok sends it to the stack's guards, which look for history-rewriting git commands, destructive shell commands and live keys. crok never waits for the answer and never blocks a call; a match is recorded as a warning on the conversation. `CROK_AGENTO11Y_GUARDS=off` stops the checks.
- **Metrics.** `crok_turns_total`, `crok_tool_runs_total`, `crok_workflow_steps_total` and `crok_guard_checks_total`, with turn and tool durations, feed the stack's harness dashboard, its alerts and its SLOs.

To turn reporting off, add `agent_observability = false` under `[features]` in `~/.crok/config.toml`, or set `CROK_AGENT_OBSERVABILITY=0`. To report to your own stack, write `~/.crok/agento11y.env` with `crates/codegen/xai-grok-agento11y/setup.sh` from the repository.

## For developers

- Releases are made by `.github/workflows/release.yml` as before: when a pull request that bumps `VERSION` merges into `main`, it builds, checks and signs every file and publishes the release with the notes in `release/notes/v2.0.2/`.
- The release workflow has a new `eval` job, which `publish` waits for. It runs the seven smoke cases of `evals/run.py` twice against the release build and fails when pass@1 drops more than 0.20 below `evals/baselines/smoke.json`, or when a safety case that always passed fails. Without the `CROK_EVAL_OPENROUTER_API_KEY` secret in the release environment it warns and passes.
- `evals/run.py` runs crok headless over small fixture repositories in three suites (`s1` regressions, `s2` tool use, `s3` safety; 22 cases) and reports pass rates, cost and behaviour per model and build. `evals/README.md` describes the cases and checks.
- `observability/agento11y/stack.json` holds the stack's evaluators, rules and guards, and `observability/agento11y/stack.py` applies them through the Agent Observability plugin API, scores conversations stored before a rule existed and installs the alerts and SLOs.
- The sampler reports each turn, tool run, step, verdict, rating and guard check through `crates/codegen/xai-grok-sampler/src/observe_harness.rs`, and the bridge records them in `crates/codegen/xai-grok-agento11y/bridge/src/harness.ts`.
- The relay's `sessions:transcript` answers a range of a session's items, newest first and without the text of thoughts and tool output, for the phones' transcript window (`relay/DESIGN.md` §3). `bridge:setModels` keeps up to 1,000 models, `devices:models` is the list clients read, and crok's viewer asks for one with `x.ai/remote/models`.
- The link to the relay folds a session's waiting updates into one write (`fold_backlog`), and `relay/scripts/status-e2e.mjs` measures how soon a phone sees a turn end through a slow relay.
- The OpenRouter request fits `max_tokens` to the context window less the estimated prompt.

## Signing

2.0.2 is signed by the same "Crok Code Signing" certificate as 2.0.1, 2.0.0, 1.5.2 and 1.5.3. macOS ties privacy permissions to the signature, so what you allowed for 2.0.1 (Screen Recording, Accessibility, microphone, speech recognition) carries over to 2.0.2. The build is not notarized, so a new install needs the **Open Anyway** step above once.

The Android app is signed with the release key that 2.0.0 introduced. The iOS app is not signed, as **Phone apps** explains. The signed list of checksums is a separate thing: it lets the updater check a download, and it does not change how macOS treats the app.

## Upgrading from 2.0.1

Use **Crok Desktop › Check for Updates…**, or `crok upgrade` in a terminal with Crok Desktop quit. This update is made in place, into the installed `Crok Desktop.app`, so it keeps its place in the Dock and Finder and no old copy is left in the Trash. It takes the image built against the same SDK as the installed app (macOS26-SDK or macOS15-SDK), never the other one.

Sign-in to your model providers, settings, tasks and the relay all carry over: 2.0.2 talks to the same production relay as 2.0.1. The phone apps are installed from this release's files, as **Phone apps** above describes.

## Details

- Bundles crok `{{CROK_VERSION}}`.
- Built by GitHub Actions from tag `desktop-v2.0.2` at `{{COMMIT}}` on `main`. The macOS 26 SDK image was built with Xcode {{XCODE26}} against the macOS {{SDK26}} SDK, the macOS 15 SDK image with Xcode {{XCODE15}} against the macOS {{SDK15}} SDK, and the standalone `crok` against the macOS {{TUI_SDK}} SDK.
- Both images are arm64, signed by the Crok Code Signing certificate and not notarized, and both run on macOS 14 Sonoma or later.
- The iOS app (`dev.chenli.crok.mobile`) is a Release build made with Xcode {{XCODE26}}; the Android app is a release build for Android 8.0 or later.
- The SHA-256 checksums are at the end of these notes and in `SHA256SUMS.txt`, which covers the phone apps too. `release/README.md` in the repository shows how to check the list's signature by hand.
