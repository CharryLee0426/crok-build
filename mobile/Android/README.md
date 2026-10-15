# Crok for Android

The Android companion app for crok remote control: follow and steer the crok sessions running on your computers
(the `crok` TUI and Crok Desktop) from a phone. It reads every session on every linked computer, streams the
transcript, sends prompts, stops a running turn, shows session info, manages linked devices and links new computers
by QR code. The design, the API contract and the Telegram pattern table are in [`relay/DESIGN.md`](../../relay/DESIGN.md).

- Kotlin, Jetpack Compose, Material 3 (Crok palette, no dynamic colour), minSdk 26, target/compileSdk 36.
- Data: the official Convex Android client (`dev.convex:android-convexmobile` 0.8.0, with JNA 5.19.1 for 16 KB page
  devices) over WebSocket; sign-in and token refresh over Convex's HTTP API.
- Six languages: English, 简体中文, 日本語, Español, Français, Deutsch (`res/values-*/strings.xml`).

## Build

Needs JDK 17+ (21 here) and the Android SDK (`platforms;android-36`, `build-tools;36.1.0`). Put the SDK path in
`local.properties` (`sdk.dir=…`, git-ignored), then:

```sh
./gradlew :app:assembleDebug          # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assembleRelease        # minified; signed with the debug key so it installs (use a real key to ship)
```

Versions live in `gradle/libs.versions.toml`: AGP 9.4.1 (built-in Kotlin), Kotlin 2.4.21, Gradle 9.8.1, Compose BOM
2026.06.01 (UI 1.11, Material 3 1.4), Navigation 2.9.8, Lifecycle 2.10.0, Activity 1.13.0, Core 1.18.0, DataStore
1.2.1, Browser 1.10.0 (Auth Tab), Play services code scanner 16.1.0, kotlinx.serialization 1.11.0, coroutines 1.11.0.
Newer AndroidX releases (Compose 1.12, Navigation 2.10, Core 1.19, Lifecycle 2.11) require compileSdk 37, so they are
held back on purpose.

## Configure the relay

The relay is a Convex deployment URL (`https://<deployment>.convex.cloud`), the same one your computers use
(`[remote] url` in `~/.crok/config.toml`).

- Build time: `./gradlew :app:assembleRelease -PcrokRelayUrl=https://<deployment>.convex.cloud` (or set
  `crokRelayUrl` in `gradle.properties`). It becomes `BuildConfig.RELAY_URL`. When empty, debug builds use
  `http://10.0.2.2:3210` — the emulator's alias for the host's `npx convex dev` — and release builds have none.
- Run time: the Welcome screen has a **Server** field ("Use another server"; always shown when the build has no relay).
  The value is saved and used for the next sign-in.
- Debug builds allow plain HTTP only to `10.0.2.2`, `127.0.0.1` and `localhost` (`src/debug/res/xml/
  network_security_config.xml`); release builds are HTTPS only.

The relay's web app must have `CROK_WEB_URL` set so `deviceAuth:start` returns an approval link; without it the
Waiting screen tells the person to enter the code on the web app by hand.

## Sign-in

Signing in is required; only the sign-in flow exists while signed out.

1. Welcome → **Continue with GitHub or Google** → `deviceAuth:start({kind:"phone", name, platform, client})`.
2. The approval page (`verificationUrlComplete&app=1`) opens in an **Auth Tab** when the default browser supports it,
   else a Custom Tab, else any browser. The page ends on `crok://signed-in`, which closes the tab (the Auth Tab returns
   it to the app; for Custom Tabs, `MainActivity` handles it through an intent filter).
3. **Waiting for approval** shows the code, a countdown, "Open again" and "Cancel", and polls `deviceAuth:poll` every
   `interval` seconds (at once when the tab closes). The pending sign-in is persisted, so a killed app resumes waiting.
4. On approval the refresh token, device id and account are stored encrypted (AES-256-GCM, key in the Android
   Keystore; ciphertext in SharedPreferences, excluded from backups).

Access tokens come from `deviceAuth:refresh` over the HTTP API, never through the WebSocket client: on every
`loginFromCache` (the Convex client's reconnect) and five minutes before expiry. A `REVOKED` answer anywhere signs the
phone out and returns to Welcome with a note.

## Demo mode

Debug builds can run on built-in demo data (three computers, sessions in every state, a reply that streams and
finishes), with no relay:

- tap **Try the demo** on the Welcome screen, or
- `adb shell am start -n dev.chenli.crok.mobile/.MainActivity --ez crokDemo true`

Prompts, Stop, info requests, pin / archive and device sign-outs all work against the in-memory relay
(`demo/DemoTransport.kt`, which answers the same Convex function names). Release builds ignore it.

## Tests

```sh
./gradlew :app:testDebugUnitTest      # unit tests + screenshot tests (images are only written when recording)
./gradlew :app:lintDebug
```

Unit tests (JVM) cover the transcript building (grouping, day headers, optimistic prompts, ticks, `mine`), user codes,
plan summary, relative times, the Markdown reader and its AnnotatedString rendering, streaming-reveal pacing, list
filtering / freezing, the HTTP API reply and error decoding, the wire models (float64 numbers), the auth state machine
with persistence across a "killed" process, token refresh and revocation, the delayed connection state, and the engine
(paging, commands, devices) against the demo relay.

### Screenshot tests

`ScreenshotTest` renders the main screens on the JVM with Robolectric native graphics and
[Roborazzi](https://github.com/takahirom/roborazzi), from the demo data, in light, dark and other languages:

```sh
./gradlew :app:recordRoborazziDebug --tests '*ScreenshotTest*'   # → app/build/outputs/roborazzi/*.png
```

### Relay integration test

`RelayIntegrationTest` signs a phone in against a running relay with the app's own `AuthController`, `TokenManager`
and HTTP client, links a "computer" on the same account that mirrors a session through the bridge functions, and
decodes `sessions:list/get/events` (including paging with `endCursor`), `commands:*`, `devices:list`, `users:me` and
`deviceAuth:pendingLogin/approve` through the app's models; then it signs everything out again. It needs the local
deployment (`npx convex dev` in `relay/`) and stands in for the person approving on the web with
`npx convex run deviceAuth:approve --identity …`:

```sh
CROK_RELAY_IT=1 CROK_NPX="$(which npx)" ./gradlew :app:testDebugUnitTest --tests '*RelayIntegrationTest*'
# CROK_RELAY_URL=http://127.0.0.1:3210 is the default.
```

## Code map

```
app/src/main/java/dev/chenli/crok/mobile/
  MainActivity.kt, CrokApplication.kt (AppGraph), AppViewModel.kt   activity, app-wide objects, auth → engine lifecycle
  auth/        AuthController (sign-in state machine), AuthStore (encrypted), TokenManager + DeviceAuthProvider
  data/        wire models, RelayJson (float64 ↔ Long), errors, Convex HTTP API, Keystore box, settings/drafts/cache
  engine/      CrokEngine (per-account facades), RelayTransport + ConvexTransport, TranscriptPager, ConnectionState
  demo/        DemoData + DemoTransport (in-memory relay for demo mode and screenshots)
  logic/       pure logic: Transcript, Markdown, RevealPacer, SessionList, PlanSummary, RelativeTime, UserCode
  ui/          CrokRoot (navigation), theme, common components, signin/, sessions/, session/, settings/
```

## Telegram patterns

Structure and UX only — Telegram is GPL and no code is copied. See the full table in `relay/DESIGN.md` §5.

| pattern | here |
|---|---|
| AccountInstance / engine facade, torn down on sign-out | `CrokEngine` (`sessions`, `events`, `commands`, `devices`, `accounts`), created and closed by `AppViewModel` |
| LoginActivity's persisted pages | `AuthController` + `AuthStore` (welcome → waiting → signed in; resumes after a kill) |
| Connection state in the title, 0.3 s delayed | `ConnectionTitle` + `delayedForDisplay()` ("Waiting for network" / "Connecting…" / "Updating…") |
| DialogCell, FilterTabsView | `SessionRowItem` (avatar + online dot, time, computer · folder, preview / working… / Needs approval, badge, pin), filter tabs |
| Swipe actions, list frozen during a swipe | `SwipeToDismissBox` (pin / archive), `SessionList.freezeOrder` |
| ChatActivity reversed, windowed history | `LazyColumn(reverseLayout = true)` over `TranscriptPager` (50 per page, `endCursor` pinning) |
| Grouping, day headers, status ticks, failed-message menu | `Transcript.build`, `TranscriptViews` (clock → ✓ → ✓✓, red "!" with Retry / Delete) |
| Streaming-stop send button, blocked when offline | `Composer` (Send / Stop / offline note) |
| TextRevealController | `RevealPacer` + `rememberRevealedLength` |
| Pinned message bar, page-down button with counter | `PlanBar`, `ScrollToBottomButton` |
| SessionsActivity (active sessions), QR login | `DevicesScreen`, `LinkComputerScreen` (Google code scanner) |
| Theme.java semantic keys | `CrokColors` (`ui/theme/Theme.kt`) |

## Not verified here

Everything that needs a device or emulator: the Convex WebSocket client (its Rust core loads through JNA on Android
only; the transport is compile-checked and the same calls are verified over the HTTP API), the Auth Tab / Custom Tab
round trip, the Keystore, the Google code scanner, notifications of network changes, and the release build on a phone.
