> **简体中文 · 日本語 · Español · Français · Deutsch**: translations of these notes follow the English text, under **Translations**.

Crok Desktop 2.0.4 is the native macOS app for this fork. It bundles crok, the agent runtime and the `crok` terminal UI, so there is nothing else to install. It follows 2.0.3, which kept every device's list of sessions current. 2.0.4 lets a prompt from the web, a phone or another computer carry photos and files, and shows them in the transcript on every device. Every session list can now be refreshed by hand, which has each online computer list its sessions again at once. Crok Desktop puts copy and thumbs up/down under every reply, the terminal asks one short question after a turn, and more reasoning models on OpenRouter now name their sessions.

This release is built and published by GitHub Actions, as soon as its pull request merged, as 2.0.3 was.

## Install

1. Download the disk image that matches your macOS version and open it. The table under **Which disk image to download** says which one.
2. Drag **Crok Desktop** onto **Applications**.
3. Open Crok Desktop from Applications. This build is not notarized, so the first time macOS says it cannot verify the app: click **Done**, open **System Settings › Privacy & Security**, click **Open Anyway** beside the Crok Desktop message, and confirm. You only do this once.
4. Sign in from **Settings › Accounts** with OpenRouter, OpenAI Codex, an Anthropic API key, a DeepSeek API key or a GLM Coding Plan key.

Requires macOS 14 Sonoma or later on Apple silicon (M1 or later).

## Which disk image to download

Both images are Crok Desktop 2.0.4 and contain the same features. They differ only in the macOS SDK they were built against, which decides whether the window chrome uses Apple's Liquid Glass:

| Disk image | Built against | Use it on | Title bar |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.4-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 and later | Liquid Glass |
| `Crok-Desktop-2.0.4-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 and 15 | Frosted blur within the window |

On macOS 26 and later, prefer the macOS 26 SDK image for the Liquid Glass title bar. On macOS 14 or 15, take the macOS 15 SDK image. It also runs on later versions, so if you are not sure which macOS you have, it is the safe choice.

`crok-2.0.4-aarch64-apple-darwin.tar.gz` is the `crok` terminal UI on its own, for a Mac where you do not want the app: unpack it and put `crok` on your `PATH`. The phone apps are described under **Phone apps**. `SHA256SUMS.txt` lists the SHA-256 of every download, and `SHA256SUMS.txt.sig` is the signature of that list, which the updater checks.

## Phone apps

The Crok app for iPhone and Android follows your computers' sessions, shows their replies and permission requests, and starts or steers tasks from anywhere. This release's phone apps are new: they send photos and files with a prompt, show them in the transcript, and have **Refresh**. Install them over the ones from 2.0.3 to get these. Phone apps from 2.0.3 and older keep working as before, without them. All three files sign in to the production relay.

- **Android 8.0 or later:** download `Crok-Android-2.0.4.apk` on the phone and open it, allowing your browser to install apps when Android asks, or run `adb install -r Crok-Android-2.0.4.apk`. It is signed with the release key that 2.0.0 introduced, so it installs over the APK of an earlier release. A Crok APK you built yourself is signed with another key and blocks the install: remove it first with `adb uninstall dev.chenli.crok.mobile`, or from the phone's settings.
- **iPhone and iPad, iOS 17 or later:** `Crok-iOS-2.0.4-unsigned.ipa` is not signed, because an app for iOS devices is signed with the Apple ID of whoever installs it. Install it with a sideloading tool such as AltStore or Sideloadly, which signs it with your Apple ID. With a free Apple ID, iOS stops opening the app after 7 days until you install it again. To build it yourself instead, use the **Release** configuration: Xcode's Run button builds Debug, which signs in to the test relay.
- **iOS Simulator:** `Crok-iOS-2.0.4-Simulator.zip` unpacks to `Crok.app`, for `xcrun simctl install booted Crok.app` on a Mac with Xcode.

To sign the phone in, tap **Continue with GitHub or Google**, sign in on the page that opens at https://crok.chenli.dev, and tap **Approve**. Then link each computer: run `crok remote login` on it and scan the QR code it shows from the app's **Settings › Link a computer**, or approve the computer on the web page that opens.

## Highlights

- **Photos and files in prompts, from any device.** On the web and in the phone apps, the paperclip next to the message field adds photos and files to a prompt: Photos, Camera and Files on the phones, and on the web also pasting and dropping them onto the session. Up to 10 go with one message, at most 20 MB each, and a message may be photos alone. The computer passes images to the model as images and saves other files in a folder of its own for the model to read. Photos show in the transcript on every device and open full screen on a tap (with **Share** and **Save** on the phones), and the images of a prompt typed on the computer itself show on the phones and the web too.
- **Refresh every session list.** The web, the phone apps, Crok Desktop's **Other computers** and the terminal's Remote panel have a Refresh control (↻, or `r` in `/remote`). It asks every online computer to list all its sessions again at once, rather than at its next check, and spins until each has done it. On the phones, pulling the list down does the same.
- **Feedback on replies.** Crok Desktop shows a copy button and thumbs up and down under every finished reply. Copying takes the reply's Markdown as written, and clicking the chosen thumb again takes the verdict back. The terminal asks "How was this response?" once under a finished turn, answered with `/good`, `/not-so-well` or `/dont-show-again`.
- **Session titles on more OpenRouter models.** Reasoning models that refuse a forced tool call (Muse Spark 1.3) or spend a short answer on reasoning (Muse Glimmer, GLM 5.3 Flash, Aion 2.0) never got a generated title, so their sessions were named after the prompt's first words. They are titled like any other model now.

## Remote control

Every crok in this release signs in to the production relay at https://crok.chenli.dev, as 2.0.3 does, and keeps the sign-in it already has. The production relay takes this release's relay changes when this release is published; what happens on a computer comes with crok 2.0.4 there.

- **Photos and files, on the computer.** Before it runs such a prompt, crok downloads its photos and files. Images go to the model as image input. Other files are saved under `~/.crok/remote/attachments/` (one folder per session and message) and linked in the prompt, the way Crok Desktop attaches files. In a task of another computer that is already open, Crok Desktop and the terminal upload a prompt's images and files with it; a new task on another computer still starts with text alone.
- **Photos and files, on the relay.** The web and the phones send photos upright, at most 2048 pixels on the long side and without their metadata, with a small preview. An upload no message claims is deleted after a day; a session's files are deleted with the session, or with its transcript after 30 idle days.
- **Older crok.** A computer that runs only crok 2.0.3 or older cannot take photos or files: sending some there says "Update crok on … to send photos and files there." Text prompts work as before.
- **Refresh.** The crok that holds a computer's list of sessions lists every session on disk again as soon as someone presses Refresh, and then keeps sending only what changes, every 30 seconds, as before. The spinner stops once every online computer has answered, or after 15 seconds. A computer that runs only older crok may answer only at its next regular listing. Offline computers cannot list their sessions: their sessions stay as they were last listed, and when no computer is online, the phones and the web say "No computer is online. The list shows what they listed last."
- **Update the computers.** Photos and files in prompts, and an immediate answer to Refresh, come with crok 2.0.4 on each computer.

## Feedback and Agent Observability

As in 2.0.3, every crok in this release reports each model call it makes, with its turns, tool runs, steps and guard checks, to [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) on the maintainer's Grafana Cloud stack, and `crok version --json` shows the host under `agentObservability`.

- **Where a thumb goes.** A thumbs up or down, from Crok Desktop or the terminal, is recorded on that turn's conversation in Agent Observability and as the `crok_feedback_rating` gauge. Taking a thumb back records it as neutral, so it no longer counts. Nothing is sent while reporting is off.
- **The question in the terminal.** It appears once under a finished turn, and not after a cancelled or failed turn, in minimal mode, or in a very short terminal. `/dont-show-again` turns it off by writing `feedback_prompt = false` under `[features]` in `~/.crok/config.toml`; set it back to `true` to see the question again.
- **The maintainer's evaluation.** A new **crok Feedback** dashboard shows the share of thumbs up among turns with feedback, with an alert under 80% over a day and a 30-day objective. The evaluation counts only once there are at least 20 verdicts in a range.

To turn reporting off, add `agent_observability = false` under `[features]` in `~/.crok/config.toml`, or set `CROK_AGENT_OBSERVABILITY=0`. To report to your own stack, write `~/.crok/agento11y.env` with `crates/codegen/xai-grok-agento11y/setup.sh` from the repository.

## For developers

- Releases are made by `.github/workflows/release.yml` as before: when a pull request that bumps `VERSION` merges into `main`, it builds, checks and signs every file, runs the eval gate and publishes the release with the notes in `release/notes/v2.0.4/`.
- Photos and files: devices upload to `files:uploadUrl` and name the uploads in `commands:sendPrompt` and `sessions:create` (`attachments`); the relay keeps them in a `files` table (owner, session, SHA-256, preview) and gives the computer's inbox and every transcript query their download URLs. Only a crok whose `features` list `attachments` is offered such prompts, and `bridge:connect` answers with the relay's own `features`. `relay/DESIGN.md` §2–§5, "Photos and files", is the contract; `relay/scripts/attachments-e2e.mjs` and `attachments-bridge-e2e.mjs` check it.
- Refresh: `sessions:refresh` (`{asked, offline, at}`) stamps `refreshAt` on each online computer's catalog; while it is later than the last upload's start, every crok there sees `catalogWanted` and `bridge:beginCatalog` grants the first to ask at once, the holder too. `sessions:refreshState({since})` names the computers still listing. The viewer's `x.ai/remote/refresh` does both for Crok Desktop and the terminal. `relay/scripts/refresh-e2e.mjs` checks it with real crok processes.
- Feedback: front ends send `x.ai/feedback/rating` (`1`, `-1`, `0` to take it back) for a turn. `[features] feedback_prompt` (default `true`, `CROK_FEEDBACK_PROMPT`) controls the terminal's question. The evaluation is the `crok Feedback` dashboard, the `crok-feedback-good-rate-low` alert and the `crok feedback is mostly positive` SLO.
- On OpenRouter, the sampler asks for a forced tool call in words with `tool_choice: "auto"`, and gives a reasoning model at least 4,096 output tokens and, unless the call names an effort, the lightest effort the catalog lists. Two `SamplerConfig` fields carry the catalog's reasoning support and lightest effort.
- The **LLM Overview** dashboard's cache hit rate now covers Claude Platform, OpenRouter and the calls crok reports itself, each queried on its own, so a source with no calls in the range adds nothing.

## Signing

2.0.4 is signed by the same "Crok Code Signing" certificate as 2.0.3, 2.0.2, 2.0.1, 2.0.0, 1.5.2 and 1.5.3. macOS ties privacy permissions to the signature, so what you allowed for 2.0.3 (Screen Recording, Accessibility, microphone, speech recognition) carries over to 2.0.4. The build is not notarized, so a new install needs the **Open Anyway** step above once.

The Android app is signed with the release key that 2.0.0 introduced. The iOS app is not signed, as **Phone apps** explains. The signed list of checksums is a separate thing: it lets the updater check a download, and it does not change how macOS treats the app.

## Upgrading from 2.0.3

Use **Crok Desktop › Check for Updates…**, or `crok upgrade` in a terminal with Crok Desktop quit. This update is made in place, into the installed `Crok Desktop.app`, so it keeps its place in the Dock and Finder and no old copy is left in the Trash. It takes the image built against the same SDK as the installed app (macOS26-SDK or macOS15-SDK), never the other one.

Sign-in to your model providers, settings, tasks and the relay all carry over: 2.0.4 talks to the same production relay as 2.0.3. Update every computer you use with the relay, so that it can take photos and files and answer Refresh at once, and install this release's phone apps, as **Phone apps** above says.

## Details

- Bundles crok `{{CROK_VERSION}}`.
- Built by GitHub Actions from tag `desktop-v2.0.4` at `{{COMMIT}}` on `main`. The macOS 26 SDK image was built with Xcode {{XCODE26}} against the macOS {{SDK26}} SDK, the macOS 15 SDK image with Xcode {{XCODE15}} against the macOS {{SDK15}} SDK, and the standalone `crok` against the macOS {{TUI_SDK}} SDK.
- Both images are arm64, signed by the Crok Code Signing certificate and not notarized, and both run on macOS 14 Sonoma or later.
- The iOS app (`dev.chenli.crok.mobile`) is a Release build made with Xcode {{XCODE26}}; the Android app is a release build for Android 8.0 or later.
- The SHA-256 checksums are at the end of these notes and in `SHA256SUMS.txt`, which covers the phone apps too. `release/README.md` in the repository shows how to check the list's signature by hand.
