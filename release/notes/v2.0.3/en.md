> **简体中文 · 日本語 · Español · Français · Deutsch**: translations of these notes follow the English text, under **Translations**.

Crok Desktop 2.0.3 is the native macOS app for this fork. It bundles crok, the agent runtime and the `crok` terminal UI, so there is nothing else to install. It follows 2.0.2, which brought the browser tool into your own Chrome and the model pickers to every device. 2.0.3 keeps every device's list of sessions current: a session made, renamed or deleted on a computer reaches the web, the phones and the other computers within about half a minute. A session started on a computer from the web or a phone now shows up on that computer too, as a task in Crok Desktop and in the terminal's Remote panel. A new session started with a chosen model always starts on that model, and crok's Claude calls are no longer counted twice in Agent Observability.

This release is built and published by GitHub Actions, as soon as its pull request merged, as 2.0.2 was.

## Install

1. Download the disk image that matches your macOS version and open it. The table under **Which disk image to download** says which one.
2. Drag **Crok Desktop** onto **Applications**.
3. Open Crok Desktop from Applications. This build is not notarized, so the first time macOS says it cannot verify the app: click **Done**, open **System Settings › Privacy & Security**, click **Open Anyway** beside the Crok Desktop message, and confirm. You only do this once.
4. Sign in from **Settings › Accounts** with OpenRouter, OpenAI Codex, an Anthropic API key, a DeepSeek API key or a GLM Coding Plan key.

Requires macOS 14 Sonoma or later on Apple silicon (M1 or later).

## Which disk image to download

Both images are Crok Desktop 2.0.3 and contain the same features. They differ only in the macOS SDK they were built against, which decides whether the window chrome uses Apple's Liquid Glass:

| Disk image | Built against | Use it on | Title bar |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.3-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 and later | Liquid Glass |
| `Crok-Desktop-2.0.3-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 and 15 | Frosted blur within the window |

On macOS 26 and later, prefer the macOS 26 SDK image for the Liquid Glass title bar. On macOS 14 or 15, take the macOS 15 SDK image. It also runs on later versions, so if you are not sure which macOS you have, it is the safe choice.

`crok-2.0.3-aarch64-apple-darwin.tar.gz` is the `crok` terminal UI on its own, for a Mac where you do not want the app: unpack it and put `crok` on your `PATH`. The phone apps are described under **Phone apps**. `SHA256SUMS.txt` lists the SHA-256 of every download, and `SHA256SUMS.txt.sig` is the signature of that list, which the updater checks.

## Phone apps

The Crok app for iPhone and Android follows your computers' sessions, shows their replies and permission requests, and starts or steers tasks from anywhere. It comes with this release as it came with 2.0.2, and works as 2.0.2's does: this release's changes are on the computers and the relay, so phone apps from 2.0.2 and 2.0.1 get them too. All three files sign in to the production relay.

- **Android 8.0 or later:** download `Crok-Android-2.0.3.apk` on the phone and open it, allowing your browser to install apps when Android asks, or run `adb install -r Crok-Android-2.0.3.apk`. It is signed with the release key that later releases keep, so the next APK installs over it. A Crok APK you built yourself is signed with another key and blocks the install: remove it first with `adb uninstall dev.chenli.crok.mobile`, or from the phone's settings.
- **iPhone and iPad, iOS 17 or later:** `Crok-iOS-2.0.3-unsigned.ipa` is not signed, because an app for iOS devices is signed with the Apple ID of whoever installs it. Install it with a sideloading tool such as AltStore or Sideloadly, which signs it with your Apple ID. With a free Apple ID, iOS stops opening the app after 7 days until you install it again. To build it yourself instead, use the **Release** configuration: Xcode's Run button builds Debug, which signs in to the test relay.
- **iOS Simulator:** `Crok-iOS-2.0.3-Simulator.zip` unpacks to `Crok.app`, for `xcrun simctl install booted Crok.app` on a Mac with Xcode.

To sign the phone in, tap **Continue with GitHub or Google**, sign in on the page that opens at https://crok.chenli.dev, and tap **Approve**. Then link each computer: run `crok remote login` on it and scan the QR code it shows from the app's **Settings › Link a computer**, or approve the computer on the web page that opens.

## Highlights

- **Every device's session list stays current.** A session that changed only on a computer's disk (made by a crok that was not signed in to the relay, renamed or deleted) used to reach the web, the phones and the other computers only with that computer's next full listing, which came about every 20 minutes and stopped when the crok sending it quit. It now arrives within about half a minute, and another crok on the computer takes the listing over as soon as the first one quits.
- **Sessions started from the web or a phone show up on their computer.** Crok Desktop adds such a session as an unread task in its project, and shows it working while a turn runs. The terminal says which device started it and lists it under **This computer** in `/remote`.
- **A new session starts on the model you picked.** A session started from the web or a phone with a chosen model and thinking level could start on the computer's default instead, when an older crok on that computer (a terminal left open from before an update, say) took it first. Only a crok that applies the choice can take it now.
- **Other computers fill in at once.** Crok Desktop's **Other computers** asks for the list again whenever its link to the relay connects, and every 5 seconds until it has an answer, instead of waiting up to 4 minutes.
- **Claude calls are reported to Agent Observability once.** Claude Platform's own telemetry export stored a second copy of every Claude call crok reported. crok now asks Anthropic's API not to export the calls it reports itself. See **Agent Observability** below.

## Remote control

Every crok in this release signs in to the production relay at https://crok.chenli.dev, as 2.0.2 does, and keeps the sign-in it already has. The production relay already runs this release's relay changes, so the rule for a chosen model below applies today; the rest comes with crok 2.0.3 on each computer.

- **Session lists.** One crok on each computer holds that computer's list: every 30 seconds it looks at the sessions on disk and sends only what changed, and every 30 minutes it sends the whole list again. When it quits or loses its connection, every other crok on that computer is asked to take the list over, and the first to answer does. A computer whose crok starts again lists its sessions at once. Computers that still run crok 2.0.2 or older keep sending their whole list themselves, now every 10 minutes instead of about every 20.
- **Sessions started elsewhere, in Crok Desktop.** A session another device started on this Mac becomes a task of its project as soon as the relay lists it, with the project too when the app has none for that folder. It is unread, takes the session's title until you open it, shows as working while a turn runs there and as unread when it ends, and opens like any other task. Each such session is added once, so a task or project you removed does not come back.
- **Sessions started elsewhere, in the terminal.** While the terminal is connected to the relay, it announces each session another device starts on this computer, for example "iPhone started a session in app: … — /resume or /remote opens it". The Remote panel lists those sessions first, under **This computer**, each marked with the device it came from ("from iPhone"). Enter opens one here, and `n` on this computer points to `/new`.
- **The chosen model.** A new session carrying a model or thinking level goes only to a crok that applies it: crok 2.0.1 and later. On a computer that runs only crok 2.0.0 or older, starting such a session fails with "Update crok on … to start a session there with a chosen model or thinking level" instead of starting on the default. A session on **Default** still starts on any crok. A prompt or retry that reopens a session that failed to start follows the same rule.
- **Update the computers.** Lists that keep up with the disk, and sessions from other devices showing up on their computer, come with crok 2.0.3 on that computer. Nothing changes on the phones.

## Agent Observability

As in 2.0.2, every crok in this release reports each model call it makes, with its turns, tool runs, steps and guard checks, to [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) on the maintainer's Grafana Cloud stack, and `crok version --json` shows the host under `agentObservability`.

- **No second copy of Claude calls.** A Claude Platform organization can export a trace span of every API request to its telemetry destinations, and Agent Observability turned each of those into a conversation of its own, named by its trace id, under the agent `claude-platform`. So every Claude call crok reported was stored twice. crok now sends the calls it reports to `api.anthropic.com` with a trace context marked not sampled, which Anthropic's API answers by exporting nothing for them. Calls crok does not report (compactions, and every call while reporting is off) are exported as before, and so are calls to other providers.
- **If your organization exports Claude telemetry,** the Claude calls crok reports to Agent Observability are no longer in that export; turn reporting off to have them there again.
- **The dashboards count crok's Claude calls in Claude Platform's place.** crok's span of such a call says `crok.unsampled = true` and carries its cache reads and thinking tokens under Claude Platform's attribute names, so the LLM Observability dashboards count it once. Calls from crok 2.0.2 and older are still counted from Claude Platform's export.
- **Copies already stored are marked.** Agent Observability cannot delete what it stored, so each of the 586 copies made by crok 1.5.0 to 2.0.2 is labelled as a copy of crok's call, which tells it apart from calls only Claude Platform saw. Each computer still on crok 2.0.2 or older keeps adding copies until it is updated.

To turn reporting off, add `agent_observability = false` under `[features]` in `~/.crok/config.toml`, or set `CROK_AGENT_OBSERVABILITY=0`. To report to your own stack, write `~/.crok/agento11y.env` with `crates/codegen/xai-grok-agento11y/setup.sh` from the repository.

## For developers

- Releases are made by `.github/workflows/release.yml` as before: when a pull request that bumps `VERSION` merges into `main`, it builds, checks and signs every file, runs the eval gate and publishes the release with the notes in `release/notes/v2.0.3/`.
- The relay keeps one catalog holder per computer: `bridge:catalogUpdate` takes the holder's changes since its last upload (`EXPIRED` once another process holds it), a released catalog puts `catalogWanted` in every crok's inbox on that computer, and `bridge:connect` lists `catalog`. `sessions:create` stores `startedFrom` (`{kind: phone | web | computer, name, at}`), and the viewer's `x.ai/remote/sessions` carries `here`, this computer's sessions started from elsewhere (the newest 100). `relay/DESIGN.md` §2–§5 describe it.
- A `create` carrying a model or thinking level is offered only to hosts whose `features` list `setup` (crok 2.0.3 lists it) or `git` (crok 2.0.1 and 2.0.2).
- `relay/scripts/sessions-live-e2e.mjs` checks two computers and a phone against a local relay: running sessions listed at once, sessions made and deleted on disk, the holder quitting, a phone's session reaching the computer's own front end. `commands-e2e` and `bridge-e2e` now check where a session with a chosen model starts and what its first turn ran on.
- Debug builds of the phone apps have a third tab, **o11y**, right of **Profile**: the owner's Grafana Cloud dashboards, evaluations and Agent Observability as phone pages, built by the relay (`o11y:page`, `o11y:refresh`; `mobile/DESIGN.md` "o11y", `relay/DESIGN.md` §3). Release builds, including this release's, do not have it, and the production relay has it turned off. `relay/scripts/o11y-setup.sh` makes the read-only service account and the deployment's variables, `o11y-preview.mjs` builds the pages without a relay, and `o11y-demo.mjs` makes the phones' demo pages.
- `observability/agento11y/stack.py duplicates [--label]` matches Claude Platform's copies of crok's calls by response id and labels each one, and `gcx_api` now asks gcx for plain JSON, so `backfill` no longer skips long conversations.

## Signing

2.0.3 is signed by the same "Crok Code Signing" certificate as 2.0.2, 2.0.1, 2.0.0, 1.5.2 and 1.5.3. macOS ties privacy permissions to the signature, so what you allowed for 2.0.2 (Screen Recording, Accessibility, microphone, speech recognition) carries over to 2.0.3. The build is not notarized, so a new install needs the **Open Anyway** step above once.

The Android app is signed with the release key that 2.0.0 introduced. The iOS app is not signed, as **Phone apps** explains. The signed list of checksums is a separate thing: it lets the updater check a download, and it does not change how macOS treats the app.

## Upgrading from 2.0.2

Use **Crok Desktop › Check for Updates…**, or `crok upgrade` in a terminal with Crok Desktop quit. This update is made in place, into the installed `Crok Desktop.app`, so it keeps its place in the Dock and Finder and no old copy is left in the Trash. It takes the image built against the same SDK as the installed app (macOS26-SDK or macOS15-SDK), never the other one.

Sign-in to your model providers, settings, tasks and the relay all carry over: 2.0.3 talks to the same production relay as 2.0.2. Update every computer you use with the relay, so that its sessions stay current everywhere. The phone apps need no update, as **Phone apps** above says.

## Details

- Bundles crok `{{CROK_VERSION}}`.
- Built by GitHub Actions from tag `desktop-v2.0.3` at `{{COMMIT}}` on `main`. The macOS 26 SDK image was built with Xcode {{XCODE26}} against the macOS {{SDK26}} SDK, the macOS 15 SDK image with Xcode {{XCODE15}} against the macOS {{SDK15}} SDK, and the standalone `crok` against the macOS {{TUI_SDK}} SDK.
- Both images are arm64, signed by the Crok Code Signing certificate and not notarized, and both run on macOS 14 Sonoma or later.
- The iOS app (`dev.chenli.crok.mobile`) is a Release build made with Xcode {{XCODE26}}; the Android app is a release build for Android 8.0 or later.
- The SHA-256 checksums are at the end of these notes and in `SHA256SUMS.txt`, which covers the phone apps too. `release/README.md` in the repository shows how to check the list's signature by hand.
