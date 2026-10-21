> **简体中文 · 日本語 · Español · Français · Deutsch**: translations of these notes follow the English text, under **Translations**.

Crok Desktop 2.0.0 is the native macOS app for this fork. It bundles crok, the agent runtime and the `crok` terminal UI, so there is nothing else to install. This release gives remote control a production relay of its own, at https://crok.chenli.dev, and for the first time carries the iOS and Android apps. Replies on the web and on phones now render as full Markdown. Updates install into the app you already have, and closing the window keeps Crok Desktop running. Because of the new relay, every computer and phone signs in to remote control once more: **Remote control** below says how.

This is also the first release built and published by GitHub Actions, as soon as its pull request merged.

## Install

1. Download the disk image that matches your macOS version and open it. The table under **Which disk image to download** says which one.
2. Drag **Crok Desktop** onto **Applications**.
3. Open Crok Desktop from Applications. This build is not notarized, so the first time macOS says it cannot verify the app: click **Done**, open **System Settings › Privacy & Security**, click **Open Anyway** beside the Crok Desktop message, and confirm. You only do this once.
4. Sign in from **Settings › Accounts** with OpenRouter, OpenAI Codex, an Anthropic API key, a DeepSeek API key or a GLM Coding Plan key.

Requires macOS 14 Sonoma or later on Apple silicon (M1 or later).

## Which disk image to download

Both images are Crok Desktop 2.0.0 and contain the same features. They differ only in the macOS SDK they were built against, which decides whether the window chrome uses Apple's Liquid Glass:

| Disk image | Built against | Use it on | Title bar |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.0-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 and later | Liquid Glass |
| `Crok-Desktop-2.0.0-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 and 15 | Frosted blur within the window |

On macOS 26 and later, prefer the macOS 26 SDK image for the Liquid Glass title bar. On macOS 14 or 15, take the macOS 15 SDK image. It also runs on later versions, so if you are not sure which macOS you have, it is the safe choice.

`crok-2.0.0-aarch64-apple-darwin.tar.gz` is the `crok` terminal UI on its own, for a Mac where you do not want the app: unpack it and put `crok` on your `PATH`. The phone apps are described under **Phone apps**. `SHA256SUMS.txt` lists the SHA-256 of every download, and `SHA256SUMS.txt.sig` is the signature of that list, which the updater checks.

## Phone apps

The Crok app for iPhone and Android follows your computers' sessions, shows their replies and permission requests, and starts or steers tasks from anywhere. Until now you built it from the repository; this release carries it. All three files sign in to the production relay.

- **Android 8.0 or later:** download `Crok-Android-2.0.0.apk` on the phone and open it, allowing your browser to install apps when Android asks, or run `adb install -r Crok-Android-2.0.0.apk`. It is signed with the release key that later releases keep, so the next APK installs over it. A Crok APK you built yourself is signed with another key and blocks the install: remove it first with `adb uninstall dev.chenli.crok.mobile`, or from the phone's settings.
- **iPhone and iPad, iOS 17 or later:** `Crok-iOS-2.0.0-unsigned.ipa` is not signed, because an app for iOS devices is signed with the Apple ID of whoever installs it. Install it with a sideloading tool such as AltStore or Sideloadly, which signs it with your Apple ID. With a free Apple ID, iOS stops opening the app after 7 days until you install it again. To build it yourself instead, use the **Release** configuration: Xcode's Run button builds Debug, which signs in to the test relay.
- **iOS Simulator:** `Crok-iOS-2.0.0-Simulator.zip` unpacks to `Crok.app`, for `xcrun simctl install booted Crok.app` on a Mac with Xcode.

To sign the phone in, tap **Continue with GitHub or Google**, sign in on the page that opens at https://crok.chenli.dev, and tap **Approve**. Then link each computer: run `crok remote login` on it and scan the QR code it shows from the app's **Settings › Link a computer**, or approve the computer on the web page that opens.

## Highlights

- **Remote control has a production relay.** Releases now sign in to their own relay, with its web app at https://crok.chenli.dev. The relay that 1.5.1 to 1.5.3 used, with its web app at https://crok-relay.vercel.app, is now for test builds only. Nothing moves over between the two, so you sign in again once. See **Remote control** below.
- **The phone apps come with the release.** The Android APK, the unsigned iOS app and an iOS Simulator build are among this release's downloads, built for the production relay. See **Phone apps** above.
- **Replies render as Markdown on the web and on phones.** Tables, headings, nested lists, task lists, quotes, links and code blocks render properly. Code is highlighted in GitHub's colours and has a **Copy** button. LaTeX math renders, inline as `$…$` or `\(…\)` and on its own line as `$$…$$` or `\[…\]`; a price such as "$5 and $10" stays text. Wide code, tables and math scroll sideways inside the reply. Images are never downloaded: they show as a link.
- **Long replies open at their end on phones.** A session whose last reply is taller than the screen opens on the end of that reply, and the scroll-to-bottom button appears while you read inside a long reply. On Android, new messages no longer pull you to the bottom while you read; sending a prompt still does. On iPhone this needs iOS 18.
- **Updates install into the app you have.** From 2.0.0 on, **Crok Desktop › Check for Updates…** and `crok upgrade` put the new version into the installed `Crok Desktop.app` in one step, so it keeps its place in the Dock and Finder and no old copy is left in the Trash. Before installing, they check that the new version is signed by the same certificate, which is what keeps the permissions macOS gave Crok Desktop (Accessibility, Screen Recording, microphone). A release signed otherwise is refused unless you run `crok upgrade --allow-new-signature`.
- **Closing the window keeps Crok Desktop running.** The red close button now hides the window, and tasks, side panel terminals, browser pages and your draft go on in the background. **⌘Q** quits. Click the Dock icon, choose the window in the **Window** menu, or use a menu command such as **New Task** to bring the window back.
- **The agent introduces itself as Crok.** The system prompt now begins "You are Crok." with every provider, where it used to name Grok even when the model was Claude, DeepSeek or GLM. `agent.system_prompt_label`, `model.<id>.system_prompt_label` and `CROK_SYSTEM_PROMPT_LABEL` still set another name.

## Remote control

Every crok in this release (the terminal UI, the one inside Crok Desktop and the standalone tarball) signs in to the production relay. `crok remote status` shows its address, `https://tacit-finch-29.convex.cloud`, and `crok version --json` shows it under `remote`.

- **Sign in again on each computer.** Run `crok remote login` (or `/remote login` in the terminal UI), or use **Settings › Remote control › Sign in…** in Crok Desktop. A page opens at https://crok.chenli.dev: sign in with GitHub or Google and click **Approve**. A phone that is already signed in can link the computer instead, by scanning the QR code from **Settings › Link a computer**.
- **The production relay starts empty.** Your account, devices, pinned and archived sessions and the order of your projects live on the relay, so the first sign-in creates a new account there, and pins and order start afresh.
- **Your 1.5.x sign-in is kept for the test builds.** The first time 2.0.0 runs, crok moves it from `~/.crok/remote/credentials.json` to `~/.crok/remote/credentials-dev.json`, and the computer shows as signed out until you sign in again.
- **Update every computer and phone.** A computer on 1.5.x, or a phone app built before this release, stays on the test relay and does not see computers on 2.0.0.

A relay of your own, set with `[remote] url` or `CROK_REMOTE_URL`, works as before.

## Agent Observability

As in 1.5.3, every crok in this release reports each model call it makes to [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) on the maintainer's Grafana Cloud stack: the prompt, the reply, tool calls, token use and timing, tagged with the computer's name. `crok version --json` shows the host it reports to, under `agentObservability`. To turn it off, add `agent_observability = false` under `[features]` in `~/.crok/config.toml`, or set `CROK_AGENT_OBSERVABILITY=0`. To report to your own stack, write `~/.crok/agento11y.env` with `crates/codegen/xai-grok-agento11y/setup.sh` from the repository.

## For developers

- Releases are made by `.github/workflows/release.yml`: when a pull request that bumps `VERSION` merges into `main`, it builds the TUI, both disk images and the phone apps, checks and signs them, and publishes the release with the notes committed in `release/notes/v2.0.0/`. `release/ci-secrets.sh` gives it the signing keys. `release/README.md` describes it all.
- `.github/workflows/ci.yml` compiles the TUI, Crok Desktop for both SDKs, the iOS app and the Android app on every pull request into `main`, and checks the notes of a `VERSION` that has no release yet.
- The relay has two environments, `relay/environments/prod.env` and `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` or `relay/scripts/deploy.sh test` deploys one, and `make clients-prod` and `make clients-test` also build the phone apps for it. crok picks its relay when it is built, with `CROK_RELAY_ENV` (prod unless it is a test build).
- `desktop/macOS/scripts/build-app.sh` builds with SwiftPM's native build system (`SWIFT_BUILD_SYSTEM` picks another), which keeps `SDKROOT` and the SDK stamp right with Xcode 27 too.
- `mobile/scripts/build-apps.sh --ios-device` adds an unsigned `.ipa` for devices, and Android release builds are signed with the keystore that `CROK_ANDROID_KEYSTORE` names.

## Signing

2.0.0 is signed by the same "Crok Code Signing" certificate as 1.5.2 and 1.5.3. macOS ties privacy permissions to the signature, so what you allowed for 1.5.3 (Screen Recording, Accessibility, microphone, speech recognition) carries over to 2.0.0. Coming from 1.5.1 or earlier, which were ad-hoc signed, macOS asks for those permissions once more. If System Settings shows Crok Desktop switched on while Crok says it is not allowed, remove it from the list with **−** and allow it again, once. The build is not notarized, so a new install needs the **Open Anyway** step above once.

The Android app is signed with the release key, new in this release. The iOS app is not signed, as **Phone apps** explains. The signed list of checksums is a separate thing: it lets the updater check a download, and it does not change how macOS treats the app.

## Upgrading from 1.5.3

Use **Crok Desktop › Check for Updates…**, or `crok upgrade` in a terminal with Crok Desktop quit. This update is still made by 1.5.3's own updater, which replaces the whole app and moves the old one to the Trash as `Crok Desktop 1.5.3.app`. Empty the Trash afterwards: that copy is a second app with Crok Desktop's identifier. Updates from 2.0.0 on install into the app in place. The update takes the image built against the same SDK as the installed app (macOS26-SDK or macOS15-SDK), never the other one.

Sign-in to your model providers, settings and tasks carry over. Remote control does not: sign in again as **Remote control** above describes, and install the phone apps from this release.

## Details

- Bundles crok `{{CROK_VERSION}}`.
- Built by GitHub Actions from tag `desktop-v2.0.0` at `{{COMMIT}}` on `main`. The macOS 26 SDK image was built with Xcode {{XCODE26}} against the macOS {{SDK26}} SDK, the macOS 15 SDK image with Xcode {{XCODE15}} against the macOS {{SDK15}} SDK, and the standalone `crok` against the macOS {{TUI_SDK}} SDK.
- Both images are arm64, signed by the Crok Code Signing certificate and not notarized, and both run on macOS 14 Sonoma or later.
- The iOS app (`dev.chenli.crok.mobile`) is a Release build made with Xcode {{XCODE26}}; the Android app is a release build for Android 8.0 or later.
- The SHA-256 checksums are at the end of these notes and in `SHA256SUMS.txt`, which now covers the phone apps too. `release/README.md` in the repository shows how to check the list's signature by hand.
