> **简体中文 · 日本語 · Español · Français · Deutsch**: translations of these notes follow the English text, under **Translations**.

Crok Desktop 2.0.1 is the native macOS app for this fork. It bundles crok, the agent runtime and the `crok` terminal UI, so there is nothing else to install. It follows 2.0.0, the release that gave remote control a production relay of its own, at https://crok.chenli.dev, and carried the iOS and Android apps for the first time. 2.0.1 is the release of the work that follows. Both phone apps are redesigned around computers, projects and topics; a session of another computer shows its branch and token figures in Crok Desktop, and its Git Graph reads that computer's repository; a remote session can start on a chosen model and thinking level; and Agent Observability prices Codex, GLM and DeepSeek calls.

This release is built and published by GitHub Actions, as soon as its pull request merged, as 2.0.0 was.

## Install

1. Download the disk image that matches your macOS version and open it. The table under **Which disk image to download** says which one.
2. Drag **Crok Desktop** onto **Applications**.
3. Open Crok Desktop from Applications. This build is not notarized, so the first time macOS says it cannot verify the app: click **Done**, open **System Settings › Privacy & Security**, click **Open Anyway** beside the Crok Desktop message, and confirm. You only do this once.
4. Sign in from **Settings › Accounts** with OpenRouter, OpenAI Codex, an Anthropic API key, a DeepSeek API key or a GLM Coding Plan key.

Requires macOS 14 Sonoma or later on Apple silicon (M1 or later).

## Which disk image to download

Both images are Crok Desktop 2.0.1 and contain the same features. They differ only in the macOS SDK they were built against, which decides whether the window chrome uses Apple's Liquid Glass:

| Disk image | Built against | Use it on | Title bar |
| --- | --- | --- | --- |
| `Crok-Desktop-2.0.1-arm64-macOS26-SDK.dmg` | macOS {{SDK26}} SDK | macOS 26 and later | Liquid Glass |
| `Crok-Desktop-2.0.1-arm64-macOS15-SDK.dmg` | macOS {{SDK15}} SDK | macOS 14 and 15 | Frosted blur within the window |

On macOS 26 and later, prefer the macOS 26 SDK image for the Liquid Glass title bar. On macOS 14 or 15, take the macOS 15 SDK image. It also runs on later versions, so if you are not sure which macOS you have, it is the safe choice.

`crok-2.0.1-aarch64-apple-darwin.tar.gz` is the `crok` terminal UI on its own, for a Mac where you do not want the app: unpack it and put `crok` on your `PATH`. The phone apps are described under **Phone apps**. `SHA256SUMS.txt` lists the SHA-256 of every download, and `SHA256SUMS.txt.sig` is the signature of that list, which the updater checks.

## Phone apps

The Crok app for iPhone and Android follows your computers' sessions, shows their replies and permission requests, and starts or steers tasks from anywhere. It comes with this release as it came with 2.0.0. All three files sign in to the production relay.

- **Android 8.0 or later:** download `Crok-Android-2.0.1.apk` on the phone and open it, allowing your browser to install apps when Android asks, or run `adb install -r Crok-Android-2.0.1.apk`. It is signed with the release key that later releases keep, so the next APK installs over it. A Crok APK you built yourself is signed with another key and blocks the install: remove it first with `adb uninstall dev.chenli.crok.mobile`, or from the phone's settings.
- **iPhone and iPad, iOS 17 or later:** `Crok-iOS-2.0.1-unsigned.ipa` is not signed, because an app for iOS devices is signed with the Apple ID of whoever installs it. Install it with a sideloading tool such as AltStore or Sideloadly, which signs it with your Apple ID. With a free Apple ID, iOS stops opening the app after 7 days until you install it again. To build it yourself instead, use the **Release** configuration: Xcode's Run button builds Debug, which signs in to the test relay.
- **iOS Simulator:** `Crok-iOS-2.0.1-Simulator.zip` unpacks to `Crok.app`, for `xcrun simctl install booted Crok.app` on a Mac with Xcode.

To sign the phone in, tap **Continue with GitHub or Google**, sign in on the page that opens at https://crok.chenli.dev, and tap **Approve**. Then link each computer: run `crok remote login` on it and scan the QR code it shows from the app's **Settings › Link a computer**, or approve the computer on the web page that opens.

**The phone apps are redesigned.** A linked computer is an account, a project is a group with topics, and a session is a topic in it. The **Sessions** tab shows the selected computer's projects and opens into their topics, **Profile** replaces **Settings**, **Archived Sessions** has its own screen, and **Appearance** offers Telegram's chat themes or a photo. The next section describes the design both apps share.

## Phones: computers, projects and topics

Both phone apps now follow the same design, after Telegram, and it replaces the session list 2.0.0 shipped. It is the same on iOS and Android.

- **Two tabs: Sessions and Profile.** The Profile tab's icon is the relay account's picture, and its badge counts unread sessions on the other computers. Holding **Sessions** offers **Mark All as Read**; holding **Profile** opens the computer switcher, as does the Sessions title.
- **The Sessions tab shows one computer.** The selected computer's projects appear as forum rows: a rounded-square avatar, its newest topic titles, whether it is working, needs approval or what the last reply previews, and its unread total. The choice is remembered on the phone; a new phone starts on the computer active last.
- **A project is a group with topics.** Opening a project lists its sessions as topic rows, each with a coloured topic icon, its title, time, folder, preview and unread badge. The project screen has search, **Mark All as Read**, **Reorder**, **Sort by Recent Activity** and a compose button; swiping a topic pins or archives it, and holding it offers Pin, Stop, Mark as Read, Archive, Move Up and Move Down.
- **Archived Sessions.** A row at the top of the Sessions tab opens the selected computer's archive. Swipe left on a session to archive it; on the Archived screen, unarchive it the same way.
- **Profile is the account page.** It shows the account's picture, name and email, then every computer with its unread badge and a checkmark on the selected one, **Link a computer**, **Devices**, **Appearance**, **Language**, **Version**, the developer's GitHub and X links, and **Sign Out**.
- **Appearance carries Telegram's chat themes.** A preview and a strip of cards offer **No Theme**, **Classic** and nine emoji themes (Home, Duckling, Snowman, Diamond, Teacher, Tulip, Purple Heart, Christmas Tree and Video Game), each in a light and a dark variant, or a photo from the library with **Blur**. A theme sets the session background and the person's own bubbles; agent bubbles stay as they are. **Color Mode** stays System, Light or Dark.
- **Each app speaks six languages.** Every new screen and string is available in English, 简体中文, 日本語, Español, Français and Deutsch.

## Highlights

- **The phone apps are redesigned.** A computer is an account, a project is a group with topics, and a session is a topic. The Sessions tab shows the selected computer, Profile replaces Settings, and sessions can wear Telegram's chat themes. See **Phones: computers, projects and topics** above.
- **Another computer's branch and tokens are in the composer footer.** In a task opened from **Other computers**, Crok Desktop shows the branch, input and output tokens, cache rate and output speed that computer last reported; they refresh when a turn ends there.
- **Git Graph and the branch picker work on that computer's repository.** They read the repository through the relay, and switching or creating a branch runs there and updates the branch every device sees. The computer that has the session needs crok 2.0.1 for this.
- **A session can start on the model you choose.** The web app's new-session screen lists the target computer's own models and thinking levels above the composer; its crok applies them before the first prompt. **Default** keeps the computer's own choice.
- **Agent Observability prices every provider's calls.** Each call's span now carries its cost in USD, where the cost came from, its backend and whether you cancelled it, so Codex, GLM and DeepSeek calls show their spend. The dashboards gain a **Codex, GLM and DeepSeek** view, 14 days of history and week-over-week comparisons.
- **Smaller fixes in Crok Desktop and crok.** The first title of a session now uses the model it currently runs on, including after a switch made before the first prompt, and starting a turn while a task is still connecting reports that instead of opening a second connection.
- **Updates install into the app you have.** From 2.0.0 on, **Crok Desktop › Check for Updates…** and `crok upgrade` put the new version into the installed `Crok Desktop.app` in one step, so it keeps its place in the Dock and Finder and no old copy is left in the Trash. Before installing, they check that the new version is signed by the same certificate, which is what keeps the permissions macOS gave Crok Desktop (Accessibility, Screen Recording, microphone). A release signed otherwise is refused unless you run `crok upgrade --allow-new-signature`.
- **The agent introduces itself as Crok.** The system prompt now begins "You are Crok." with every provider, where it used to name Grok even when the model was Claude, DeepSeek or GLM. `agent.system_prompt_label`, `model.<id>.system_prompt_label` and `CROK_SYSTEM_PROMPT_LABEL` still set another name.

## Remote control

Every crok in this release (the terminal UI, the one inside Crok Desktop and the standalone tarball) signs in to the production relay. `crok remote status` shows its address, `https://tacit-finch-29.convex.cloud`, and `crok version --json` shows it under `remote`.

- **Start a session on the model and thinking level you want.** On the web, the new-session screen lists the target computer's models and thinking levels above the composer, and that computer applies them before the first prompt. **Default** leaves its own choice.
- **A task of another computer shows its figures.** The composer footer shows the session's branch, input and output tokens, cache rate and output speed, as its computer reported them at the end of its last turn.
- **Read and switch another computer's repository.** In Crok Desktop, **Git Graph** and the branch picker of a task in **Other computers** read that computer's repository through the relay; switching or creating a branch runs there, and the branch a command checks out updates the session's row for every device. The computer that has the session needs crok 2.0.1; an older crok answers that it must be updated.
- **Your sign-in carries over from 2.0.0.** A computer on 2.0.0 is signed in to the production relay already, and 2.0.1 uses that same sign-in: there is no sign-in again, and no file to move. The 1.5.x sign-in was moved from `~/.crok/remote/credentials.json` to `~/.crok/remote/credentials-dev.json` by 2.0.0, which ran that move once; 2.0.1 leaves both files where they are.
- **The production relay is where it was.** Your account, devices, pinned and archived sessions and the order of your projects live on the relay, and 2.0.1 reads them from the same place, so nothing moves over when you update.
- **Update every computer and phone.** A computer on 1.5.x, or a phone app built before 2.0.0, stays on the test relay and does not see computers on 2.0.0 or later.

A relay of your own, set with `[remote] url` or `CROK_REMOTE_URL`, works as before.

## Agent Observability

As in 2.0.0, every crok in this release reports each model call it makes to [Grafana Agent Observability](https://grafana.com/docs/grafana-cloud/machine-learning/agent-observability/) on the maintainer's Grafana Cloud stack: the prompt, the reply, tool calls, token use and timing, tagged with the computer's name. `crok version --json` shows the host it reports to, under `agentObservability`. To turn it off, add `agent_observability = false` under `[features]` in `~/.crok/config.toml`, or set `CROK_AGENT_OBSERVABILITY=0`. To report to your own stack, write `~/.crok/agento11y.env` with `crates/codegen/xai-grok-agento11y/setup.sh` from the repository.

Each call's span now also carries `crok.cost.usd`, `crok.cost.source`, `crok.backend` and, for a call you interrupted, `crok.cancelled`. The cost is the provider's own figure when it reports one, otherwise the model's standard API price for the call's tokens. Codex, GLM and DeepSeek calls are therefore priced even though those providers export no traces. The dashboards include a **Codex, GLM and DeepSeek** view, keep 14 days of history and compare each week with the one before.

## For developers

- Releases are made by `.github/workflows/release.yml`: when a pull request that bumps `VERSION` merges into `main`, it builds the TUI, both disk images and the phone apps, checks and signs them, and publishes the release with the notes committed in `release/notes/v2.0.1/`. `release/ci-secrets.sh` gives it the signing keys. `release/README.md` describes it all.
- The release runners add the imported signing keychain to the user keychain search list, then sign a throwaway copy of `/usr/bin/true` before any build: `.github/scripts/release/import-codesign.sh` stops a job in its import step when `codesign` cannot use that keychain, instead of after a 46-minute build.
- `.github/workflows/ci.yml` compiles the TUI, Crok Desktop for both SDKs, the iOS app and the Android app on every pull request into `main`, and checks the notes of a `VERSION` that has no release yet.
- Both phone apps implement `mobile/DESIGN.md`, the contract for computers as accounts, projects as groups with topics, Profile and session themes. It replaces the phone part of `relay/DESIGN.md` §5; the web app keeps that one.
- The relay has two environments, `relay/environments/prod.env` and `relay/environments/dev.env`. `relay/scripts/deploy.sh prod` or `relay/scripts/deploy.sh test` deploys one, and `make clients-prod` and `make clients-test` also build the phone apps for it. crok picks its relay when it is built, with `CROK_RELAY_ENV` (prod unless it is a test build).
- The relay's `git` command type carries `commands:git` (`{op: "graph"|"branches"|"files"|"diff"|"workspace"|"workspace_diff"|"signature"|"switch"|"create", …}`) to any crok on the session's computer that advertises `git`, and `bridge:setBranch` records a branch a command checked out. A session's row now carries `gitBranch` and `usage`, including `outputTokensPerSecond`.
- The Agent Observability bridge writes `crok.cost.usd`, `crok.cost.source`, `crok.backend` and `crok.cancelled` onto each span. `observability/grafana-llm/build_dashboards.py` generates the **Codex, GLM and DeepSeek** dashboard and the 64 history rules, and `prices.json` holds the standard API prices.
- `desktop/macOS/scripts/build-app.sh` builds with SwiftPM's native build system (`SWIFT_BUILD_SYSTEM` picks another), which keeps `SDKROOT` and the SDK stamp right with Xcode 27 too.
- `mobile/scripts/build-apps.sh --ios-device` adds an unsigned `.ipa` for devices, and Android release builds are signed with the keystore that `CROK_ANDROID_KEYSTORE` names. Debug builds of both apps wear a yellow icon; release builds the blue one.

## Signing

2.0.1 is signed by the same "Crok Code Signing" certificate as 2.0.0, 1.5.2 and 1.5.3. macOS ties privacy permissions to the signature, so what you allowed for 2.0.0 (Screen Recording, Accessibility, microphone, speech recognition) carries over to 2.0.1. The build is not notarized, so a new install needs the **Open Anyway** step above once.

The Android app is signed with the release key that 2.0.0 introduced. The iOS app is not signed, as **Phone apps** explains. The signed list of checksums is a separate thing: it lets the updater check a download, and it does not change how macOS treats the app.

## Upgrading from 2.0.0

Use **Crok Desktop › Check for Updates…**, or `crok upgrade` in a terminal with Crok Desktop quit. This update is made in place, into the installed `Crok Desktop.app`, so it keeps its place in the Dock and Finder and no old copy is left in the Trash. It takes the image built against the same SDK as the installed app (macOS26-SDK or macOS15-SDK), never the other one.

Sign-in to your model providers, settings, tasks and the relay all carry over: 2.0.1 talks to the same production relay as 2.0.0. The phone apps are installed from this release's files, as **Phone apps** above describes.

## Details

- Bundles crok `{{CROK_VERSION}}`.
- Built by GitHub Actions from tag `desktop-v2.0.1` at `{{COMMIT}}` on `main`. The macOS 26 SDK image was built with Xcode {{XCODE26}} against the macOS {{SDK26}} SDK, the macOS 15 SDK image with Xcode {{XCODE15}} against the macOS {{SDK15}} SDK, and the standalone `crok` against the macOS {{TUI_SDK}} SDK.
- Both images are arm64, signed by the Crok Code Signing certificate and not notarized, and both run on macOS 14 Sonoma or later.
- The iOS app (`dev.chenli.crok.mobile`) is a Release build made with Xcode {{XCODE26}}; the Android app is a release build for Android 8.0 or later.
- The SHA-256 checksums are at the end of these notes and in `SHA256SUMS.txt`, which now covers the phone apps too. `release/README.md` in the repository shows how to check the list's signature by hand.
