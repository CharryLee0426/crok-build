> **简体中文 · 日本語 · Español · Français · Deutsch**: translations of these notes follow the English text, under **Translations**.

Crok Desktop 2.1.0 is the native macOS app for this fork. It bundles crok, the agent runtime and the `crok` terminal UI, so there is nothing else to install. It follows 2.0.4, which brought photos and files to remote prompts. 2.1.0 adds the Meta Model API as a seventh provider, with its Muse models, to the terminal and to Crok Desktop. The web and the phone apps now show a session's model and thinking level together, including for sessions opened from the list. Crok Desktop draws its glass only in the active window and paints the composer's glass itself, so an idle window behind other apps costs about what a plain window does and Mission Control stays smooth. A selected feedback thumb now fills in, and the status dot of **Other computers** is larger and green when online.

This release is built and published by GitHub Actions, as soon as its pull request merged, as 2.0.4 was.

## Install

1. Download the disk image that matches your macOS version and open it. The table under **Which disk image to download** says which one.
2. Drag **Crok Desktop** onto **Applications**.
3. Open Crok Desktop from Applications. This build is not notarized, so the first time macOS says it cannot verify the app: click **Done**, open **System Settings › Privacy & Security**, click **Open Anyway** beside the Crok Desktop message, and confirm. You only do this once.
4. Sign in from **Settings › Accounts** with OpenRouter, OpenAI Codex, an Anthropic API key, a DeepSeek API key, a Meta Model API key or a GLM Coding Plan key.

Requires macOS 14 Sonoma or later on Apple silicon (M1 or later).

## Which disk image to download

Both images are Crok Desktop 2.1.0 and contain the same features. They differ only in the macOS SDK they were built against, which decides whether the window chrome uses Apple's Liquid Glass:

| Disk image | Built against | Use it on | Title bar |
| --- | --- | --- | --- |
| `Crok-Desktop-2.1.0-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 and later | Liquid Glass |
| `Crok-Desktop-2.1.0-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 and 15 | Frosted blur within the window |

On macOS 26 and later, prefer the macOS 26 SDK image for the Liquid Glass title bar. On macOS 14 or 15, take the macOS 15 SDK image. It also runs on later versions, so if you are not sure which macOS you have, it is the safe choice. The composer is drawn the same way in both images.

`crok-2.1.0-aarch64-apple-darwin.tar.gz` is the `crok` terminal UI on its own, for a Mac where you do not want the app: unpack it and put `crok` on your `PATH`. The phone apps are described under **Phone apps**. `SHA256SUMS.txt` lists the SHA-256 of every download, and `SHA256SUMS.txt.sig` is the signature of that list, which the updater checks.

## Phone apps

The Crok app for iPhone and Android follows your computers' sessions, shows their replies and permission requests, and starts or steers tasks from anywhere. This release's phone apps are new: an open session shows its model and thinking level together, and a model that an older computer names the provider's way is still found in the list. Install them over the ones from 2.0.4 to get this. Phone apps from 2.0.4 and older keep working as before. All three files sign in to the production relay.

- **Android 8.0 or later:** download `Crok-Android-2.1.0.apk` on the phone and open it, allowing your browser to install apps when Android asks, or run `adb install -r Crok-Android-2.1.0.apk`. It is signed with the release key that 2.0.0 introduced, so it installs over the APK of an earlier release. A Crok APK you built yourself is signed with another key and blocks the install: remove it first with `adb uninstall dev.chenli.crok.mobile`, or from the phone's settings.
- **iPhone and iPad, iOS 17 or later:** `Crok-iOS-2.1.0-unsigned.ipa` is not signed, because an app for iOS devices is signed with the Apple ID of whoever installs it. Install it with a sideloading tool such as AltStore or Sideloadly, which signs it with your Apple ID. With a free Apple ID, iOS stops opening the app after 7 days until you install it again. To build it yourself instead, use the **Release** configuration: Xcode's Run button builds Debug, which signs in to the test relay.
- **iOS Simulator:** `Crok-iOS-2.1.0-Simulator.zip` unpacks to `Crok.app`, for `xcrun simctl install booted Crok.app` on a Mac with Xcode.

To sign the phone in, tap **Continue with GitHub or Google**, sign in on the page that opens at https://crok.chenli.dev, and tap **Approve**. Then link each computer: run `crok remote login` on it and scan the QR code it shows from the app's **Settings › Link a computer**, or approve the computer on the web page that opens.

## Highlights

- **Meta Model API, a seventh provider.** The terminal and Crok Desktop sign in to Meta's own Model API, which is billed per token to a Meta account, with a key from dev.meta.ai. `crok login meta` asks for the key without showing it and checks it with Meta before saving it; a refused key is not saved. `meta-code` and `muse` are aliases, `META_API_KEY` and `MODEL_API_KEY` sign in the same way, and `crok logout meta` removes the saved key. Crok Desktop's **Settings › Accounts** and the terminal's first-run menu list the provider.
- **The Muse models.** Signing in fetches your account's model list, which then refreshes every hour. The built-in list is Muse Wonder, Muse Spark 1.3, 1.2 and 1.1, their Contributor-mode variants, and Muse Ember; a model Meta releases later works at once by its `meta/<model>` ID. The models read text, images, PDFs, audio and video. They always reason: `/effort` offers `minimal`, `low`, `medium`, `high`, `xhigh` and `max`, with `max` the default on Muse Wonder and Muse Ember and `high` on Muse Spark. `none` is not offered because Meta refuses it, and the Contributor variants stop at `xhigh`.
- **A session's model and thinking level, always together.** Opening a session on the web, iOS or Android could show only the bare model id and no thinking pill. Crok now names a session's model by the id of its model list, so the devices find the model and its levels. A session from an older crok, which names the model the provider's way, is still found by the id without its provider, then by name. The thinking pill shows the session's level while the list loads, and names a level the model's list lacks instead of saying **Default**. It is left out only for a model the list says has no levels, or when neither the list nor the session names a level.
- **Glass that costs less to draw.** Only the active window's glass is live, as with the system's own sidebars: a window behind other apps paints solid colours and the welcome page's starters stop rolling. Swiping into Mission Control no longer stutters, especially with an external display. On an M1 with a 4K display, Mission Control with Crok behind Finder went from 14.1 to 8.9 mean GPU use (p90 46 to 31).
- **The composer, drawn instead of Liquid Glass.** The window server renders Liquid Glass again whenever anything in its window changes, a blinking caret included. The composer's surface is now drawn from a frosted material and one canvas holding its shadow, fill, lit rim, glow and hairline, matching the system's look within a few levels out of 255. On the same M1 and 4K display, the GPU use of an idle Crok in front went from about 25 to 10.6, and of Mission Control with Crok in front from 18.8 to 13.0.
- **Smaller touches.** A thumbs up or down fills in when chosen, so the verdict reads at a glance. The online dot of **Other computers** is 10 points, green and haloed, and the offline one is the same size in grey.

## Remote control

Every crok in this release signs in to the production relay at https://crok.chenli.dev, as 2.0.4 does, and keeps the sign-in it already has. The production relay serves this release's web changes when this release is published; what happens on a computer comes with crok 2.1.0 there.

- **Model names.** A session keeps its model as the provider calls it (`claude-sonnet-5-5`, `deepseek-flash`, OpenRouter's `deepseek/deepseek-v4.1-flash`), while the list crok publishes names it by catalog key (`anthropic/claude-sonnet-5-5`, `deepseek/deepseek-flash`, `openrouter/deepseek/deepseek-v4.1-flash`). crok 2.1.0 sends the list's id, so the web and the phones find the model and its thinking levels. A model the computer no longer offers keeps its name.
- **Older crok.** A computer that runs crok 2.0.4 or older still names the model the provider's way. The web and this release's phone apps find it by the id without its provider, so the model and its level still show; the bare id appears only when neither form matches.
- **Both pills.** The web, iOS and Android show the session's model and thinking level together. While the computer's list is on its way, the model is named and the thinking pill shows the session's level; with no list from an older crok, both are dimmed and a tap says that the computer cannot offer model choices yet. A level missing from the model's list shows by its level name.
- **Update the computers.** The Meta Model API and the exact model names come with crok 2.1.0 on each computer. Install this release's phone apps, as **Phone apps** above says, for the two pills.

## Feedback and Agent Observability

Reporting is unchanged from 2.0.4: every crok reports each model call it makes, with its turns, tool runs, steps and guard checks, to [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) on the maintainer's Grafana Cloud stack, and `crok version --json` shows the host under `agentObservability`. A thumbs up or down from Crok Desktop or the terminal is recorded on that turn's conversation and as the `crok_feedback_rating` gauge; taking it back records it as neutral.

To turn reporting off, add `agent_observability = false` under `[features]` in `~/.crok/config.toml`, or set `CROK_AGENT_OBSERVABILITY=0`. To report to your own stack, write `~/.crok/agento11y.env` with `crates/codegen/xai-grok-agento11y/setup.sh` from the repository.

## For developers

- Meta is an `ApiBackend` (`meta`) with a Chat Completions dialect of its own. `GET /v1/models` is fetched at sign-in and hourly, and cached in `~/.crok/meta-models.json`; the built-in list stands in until the first fetch. `provider_compat.rs` sends `none` and `minimal` as `minimal`, raises any `max_tokens` below 4,096 because reasoning comes from the same budget, asks for a forced tool call in words with `tool_choice: "auto"`, keeps native JSON schemas, removes `reasoning_content` from replayed turns, and removes `frequency_penalty` and `presence_penalty`.
- A model switch between families compacts first, as for Anthropic. Standard costs are estimated from Meta's published prices, including Muse Ember's 200K-input long-context tier and the Contributor rates.
- Remote: `bridge:upsertSession` (only when the model changed), `bridge:catalogBatch` and `catalogUpdate` name a session's model by the catalog key that `selectable_catalog_key_for_persisted` resolves, the way a resumed session's model is resolved. A model the list lacks keeps its name. `relay/DESIGN.md` and `mobile/DESIGN.md` describe the contract.
- The web, iOS and Android find a session's model by id, else by the id without its provider, else by name, and show the thinking pill whenever the session names a level. The web preview has the new cases (`session-provider-model`, `session-models-loading`, `session-unknown-model`).
- Desktop: `GlassBackdrop` uses the solid colours while a window is inactive and tints over another region's backdrop instead of blurring the desktop again; `GlassSurface` draws its `FrostedGlass` look in one canvas. Tests check that no Liquid Glass layers remain and that inactive windows paint solid.
- Releases are made by `.github/workflows/release.yml` as before: when a pull request that bumps `VERSION` merges into `main`, it builds, checks and signs every file, runs the eval gate and publishes the release with the notes in `release/notes/v2.1.0/`.

## Signing

2.1.0 is signed by the same "Crok Code Signing" certificate as 2.0.4, 2.0.3, 2.0.2, 2.0.1, 2.0.0, 1.5.2 and 1.5.3. macOS ties privacy permissions to the signature, so what you allowed for 2.0.4 (Screen Recording, Accessibility, microphone, speech recognition) carries over to 2.1.0. The build is not notarized, so a new install needs the **Open Anyway** step above once.

The Android app is signed with the release key that 2.0.0 introduced. The iOS app is not signed, as **Phone apps** explains. The signed list of checksums is a separate thing: it lets the updater check a download, and it does not change how macOS treats the app.

## Upgrading from 2.0.4

Use **Crok Desktop › Check for Updates…**, or `crok upgrade` in a terminal with Crok Desktop quit. This update is made in place, into the installed `Crok Desktop.app`, so it keeps its place in the Dock and Finder and no old copy is left in the Trash. It takes the image built against the same SDK as the installed app (macOS26-SDK or macOS15-SDK), never the other one.

Sign-in to your model providers, settings, tasks and the relay all carry over: 2.1.0 talks to the same production relay as 2.0.4. Update every computer you use with the relay to crok 2.1.0 for the Meta Model API and the exact model names, and install this release's phone apps, as **Phone apps** above says.

## Details

- Bundles crok `{{CROK_VERSION}}`.
- Built by GitHub Actions from tag `desktop-v2.1.0` at `{{COMMIT}}` on `main`. The macOS 26 SDK image was built with Xcode {{XCODE26}} against the macOS {{SDK26}} SDK, the macOS 15 SDK image with Xcode {{XCODE15}} against the macOS {{SDK15}} SDK, and the standalone `crok` against the macOS {{TUI_SDK}} SDK.
- Both images are arm64, signed by the Crok Code Signing certificate and not notarized, and both run on macOS 14 Sonoma or later.
- The iOS app (`dev.chenli.crok.mobile`) is a Release build made with Xcode {{XCODE26}}; the Android app is a release build for Android 8.0 or later.
- The SHA-256 checksums are at the end of these notes and in `SHA256SUMS.txt`, which covers the phone apps too. `release/README.md` in the repository shows how to check the list's signature by hand.
