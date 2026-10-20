# Crok for Android

The Android companion app for crok remote control: follow and steer the crok sessions running on your computers
(the `crok` TUI and Crok Desktop) from a phone. It reads every session on every linked computer, streams the
transcript, sends prompts, stops a running turn, shows session info, manages linked devices and links new computers
by QR code. The design, the API contract and the Telegram pattern table are in [`relay/DESIGN.md`](../../relay/DESIGN.md).

- Kotlin, Jetpack Compose, Material 3 (Crok palette, no dynamic colour), minSdk 26, target/compileSdk 36.
- Data: the official Convex Android client (`dev.convex:android-convexmobile` 0.8.0, with JNA 5.19.1 for 16 KB page
  devices) over WebSocket; sign-in and token refresh over Convex's HTTP API.
- Replies in Markdown: `org.commonmark` 0.30.0 (CommonMark + GFM tables, strikethrough, task lists, autolinks) and
  `ru.noties:jlatexmath-android` 0.2.0 for LaTeX math; code highlighting is built in.
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

## The relay

Nobody types the relay's address: like crok itself, the app has it built in. `BuildConfig.RELAY_URL` is
`https://limitless-badger-727.convex.cloud` in debug and release builds alike (`builtInRelayUrl` in
`app/build.gradle.kts`), and the sign-in screens have no server field.

- Development only: `./gradlew :app:assembleDebug -PcrokRelayUrl=http://10.0.2.2:3210` (the emulator's alias for the
  host's `npx convex dev`), or `crokRelayUrl` in `gradle.properties`. The build refuses a value that is not an
  `http(s)://host[:port]` URL.
- Debug builds allow plain HTTP only to `10.0.2.2`, `127.0.0.1` and `localhost` (`src/debug/res/xml/
  network_security_config.xml`); release builds are HTTPS only.
- A signed-in phone keeps using the relay it signed in to (stored with its credentials); Settings › About shows it.

The relay's web app must have `CROK_WEB_URL` set so `deviceAuth:start` returns an approval link; without it the
Waiting screen tells the person to enter the code on the web app by hand.

## Sign-in

Signing in is required; only the sign-in flow exists while signed out.

1. Welcome → **Continue with GitHub or Google** → `deviceAuth:start({kind:"phone", name, platform, client})` on the
   built-in relay.
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

## The session list

As on the web and iOS (relay/DESIGN.md §5, "The session list"): every session on every linked computer — also the ones
no crok runs right now, listed from the computer's disk — grouped by project, in an order the person sets and every
client shares.

- **All** and one tab per computer show `sessions:groups` (a computer tab keeps that computer's projects); **Archived**
  stays a flat `sessions:list({archived: true})`.
- A section header has a folder icon, the project's name, on All the computer (with its online dot), the session count
  and a chevron. Tapping it collapses the project (remembered on this phone per project key, `CollapsedProjectsStore`);
  a section shows 5 sessions, then "Show N more" / "Show less". A row's second line shows the session's own folder
  only when it is not the project's name.
- **Reorder** (toolbar) shows the projects with drag handles; tap a project to move its sessions instead (pinned ones
  stay first). Long-press menus have **Move up** / **Move down** on projects and sessions and **Sort by recent activity**
  on a project; the toolbar menu has **Sort projects by recent activity**. Moves are optimistic: `CrokEngine` shows them
  at once and drops its local copy once `sessions:groups` reflects them, or takes them back if the relay refuses. Search
  keeps the matching sessions per project, hides empty projects and turns reordering off.
- A session listed from disk opens on "Loading from <computer>…" while that computer is online (`sessions:watch` asks
  a crok there for the history, and asks again when the computer comes back online), else "<computer> is offline…".
- Rows are dimmed only when their computer is offline (`deviceOnline`). A session nobody runs on an online computer
  looks like any other and takes prompts: a crok there opens it when the prompt arrives. The session header then reads
  "idle", and the composer is blocked only while the computer is offline ("<computer> is offline. Start crok or Crok
  Desktop there…"). Stop on such a session drops prompts nobody picked up; its info sheet shows the numbers the
  computer last sent (`result.stored`).
- A permission request the session waits on (`sessions:get` → `pending`) shows as a card above the composer: "Crok on
  <computer> asks:", the request, its detail in a scrollable monospaced box, and one button per option (allowing ones
  filled). Tapping one calls `commands:answer`; the buttons stay disabled until the request leaves the session, and
  `EXPIRED` (another device answered first) is ignored quietly.

## New sessions and composer commands

As on the web and iOS (relay/DESIGN.md §5, "New sessions" and "Commands in the composer"):

- Each project section of an online computer has a "+" (and **New session** in its long-press menu); the top bar's
  compose button first asks for the project (online computers' projects, grouped by computer, recent first). Both open
  the **new-session screen**: "New session" with the project and computer under it, "Starts in <path> on <computer>",
  and the composer. Sending calls `sessions:create` and the same screen turns into that session (same navigation
  entry), the prompt shown at once with its ticks (`commands:forSession` lists `create` commands like prompts). Rows
  and headers of a `starting` session say "Starting…". A failure shows the relay's own message on the bubble (e.g. a
  computer whose crok is too old: "update crok there"), with Retry.
- The composer's blue **Menu** pill (☰ "Menu" on an empty field, just ☰ while typing) or a leading `/` opens the command
  list above it, filtered by prefix: the phone's own `/new [prompt]`, `/model [name]`, `/think [level]` (only when the
  model has levels), `/stop` (only while running) and `/info`, then the session's (`sessions:commands`). A command that
  takes arguments fills the field; the others run at once. Any other `/text` goes to the computer as a prompt.
- `/model` and `/think` answer with a local **bot card** in the transcript and an inline keyboard (`sessions:get` →
  `models`; the current choice marked ✓; thinking levels two per row). A tap calls `commands:setConfig` and spins until
  `commands:get` says done; the card then reads "Model: Grok 4 ✓". With an argument they match by id, level or name
  (exact first, else a unique prefix) and apply directly. Without `models` the card says the computer is offline, or —
  online but no models — that its crok needs an update.

## Look: Liquid Glass

The top bars (with the folder tabs as capsules), the home tab bar (a floating capsule), the composer and the floating
buttons are glass over the content that scrolls beneath them, like iOS 26: the content is blurred, saturated and bent
at the glass's edge, under a light tint with a rim and a specular highlight, in continuous-corner ("squircle") shapes.
It is drawn with Kyant's [backdrop](https://github.com/Kyant0/AndroidLiquidGlass) 1.0.6 (`ui/common/Glass.kt`,
`GlassBars.kt`): the screen's content records itself into a layer and every glass surface draws that layer with the
effects. The lens and highlight need Android 13 (runtime shaders), the blur Android 12; on Android 11 and older the
glass is a translucent frosted surface with a drawn rim (`GlassLevel`). The 2.x line of the library moved to Compose
Multiplatform 1.12, which needs compileSdk 37, so it waits like the AndroidX updates above. Accent: Telegram blue
(`#3390EC` light, `#3E88F7` dark); the person's own bubbles are `#E1EFFD` (light) and `#2B5278` with white text (dark).

## Replies in Markdown

Agent replies render as full GitHub-flavoured Markdown with math, natively and the same way as the web and iOS
(relay/DESIGN.md §5, "Replies in Markdown"); thoughts, tool output and prompts stay plain.

- `logic/MathExtractor` finds math before parsing (`$…$`, `\(…\)` inline; `$$…$$`, `\[…\]` display; code untouched;
  a single `$` follows the pandoc rule so money and shell variables stay text) and swaps in placeholders.
  `logic/Markdown` parses with commonmark-java and maps the tree onto the app's own `MdBlock` / `MdInline` model:
  headings, paragraphs (a single newline stays a line break), nested lists and quotes holding any blocks, task items,
  rules, code, tables with alignment, display math. Only `http`, `https` and `mailto` links open; images become
  "🖼 alt" links and are never fetched; raw HTML stays text except `<br>`.
- `logic/SyntaxHighlighter`: one regex alternation per language (the contract's list of languages and aliases),
  identifiers classified by keyword sets, GitHub's light and dark colours (`SyntaxColors` in the theme). An unknown or
  missing language is plain monospace. Results are cached per text.
- `ui/session/MarkdownText`: code blocks with a language + Copy header, scrolling sideways; tables in a custom layout
  (each column as wide as its widest cell up to 260 dp, cells wrap beyond, tinted bold header, hairline grid) that
  scrolls sideways when wider than the bubble; display math centred, or scrolling when wider. Inline math sits on the
  text's baseline (`InlineTextContent`); a formula wider than 60 % of the window is lifted out as a display block.
- `ui/session/MathImages`: JLatexMath draws each formula white on transparent, trimmed to its ink and tinted with the
  text colour when drawn; bitmaps are cached. JLatexMath's start-up (~0.4 s: fonts, symbol tables) runs in the
  background the first time a reply has math, and formulas show their TeX source until it is done. TeX it cannot parse
  shows as its source, monospaced and muted. Release builds keep JLatexMath's classes (`proguard-rules.pro`; it loads
  them by name).
- commonmark-java 0.30.0 calls `List.of` / `Set.of` / `Map.of` (API 30); D8 backports them for minSdk 26 (the dex
  holds `$$ExternalSyntheticBackport` helpers and no direct calls). Nothing else it uses is newer than API 26.

## Staying connected

A phone's socket dies while the app is suspended or the network changes, and the Convex client does not always notice
or recover (relay/DESIGN.md §5, "Staying connected"). `RelayConnection` (engine) keeps the app working without being
killed:

- On returning to the foreground (`ProcessLifecycleOwner`), when the network comes back or the default network changes
  (Wi-Fi ↔ mobile data), and when nothing has synced for 20 s while the network is up, it refreshes the token on the
  socket (a live socket answers with a fresh result for every subscription); if nothing arrives within 10 s it replaces
  the Convex client. Live queries move to the new client by themselves and screens keep what they show; a mutation still
  running on the old client gets 10 s, then goes again on the new one (all of the app's mutations are safe to repeat).
  The old client's native core is destroyed (the Convex client never frees it itself).
- `UNAUTHENTICATED` from a query or mutation refreshes the token and replaces the client at once; `REVOKED` signs out.
  Repeated replacements back off (10 s, 20 s, … up to 2 min).
- `TokenManager` no longer lets a failed refresh wipe a still-valid token: the Convex client caches whatever its auth
  callback returns on a reconnect, and a null made it reconnect without a user for good (every query then failed with
  `UNAUTHENTICATED` and nothing reconnected it — the "lost the connection, no sessions until I kill the app" bug).

## Demo mode

Debug builds can run on built-in demo data (three computers, several projects, sessions in every state including ones
listed from disk and one waiting on a permission request, a reply that streams and finishes, and "Render every Markdown
feature" with the shared showcase reply, `relay/scripts/markdown-showcase.md`, copied verbatim into
`src/main/resources/demo/`), with no relay:

- tap **Try the demo** on the Welcome screen, or
- `adb shell am start -n dev.chenli.crok.mobile/.MainActivity --ez crokDemo true`

Prompts (also to a session nobody runs, which the demo computer then opens), Stop, info requests, answering the
permission request (the turn goes on: the build runs, or is skipped on Reject), pin / archive, reordering projects and
sessions, loading a listed session's history, new sessions (on the MacBook; the Studio runs an "older crok" that offers
no models and cannot start sessions), `/model` and `/think` and device sign-outs all work against the in-memory relay
(`demo/DemoTransport.kt`, which answers the same Convex function names). Release builds ignore it.

## Tests

```sh
./gradlew :app:testDebugUnitTest      # unit tests + screenshot tests (images are only written when recording)
./gradlew :app:lintDebug
```

Unit tests (JVM) cover the transcript building (grouping, day headers, optimistic prompts, ticks, `mine`), user codes,
plan summary, relative times, Markdown (`MarkdownTest`: the tree mapping, links, images, HTML, streaming text;
`MathExtractorTest`: DESIGN.md's math test vectors and placeholders; `SyntaxHighlighterTest`: languages, aliases,
tokens, and the showcase's parse + highlight time per streaming frame; `MathImagesTest`: JLatexMath under
Robolectric; `DemoDataTest`: the showcase copy matches the relay's), streaming-reveal pacing, the
project sections (tabs, 5 + "Show more", collapse, search, freezing, the folder line), the ordering rules (the relay's
`reorderWithin`, pinned first, Move up / Move down, sort by recent), the HTTP API reply and error decoding, the wire
models (float64 numbers, `sessions:groups`, `pending`, stored info), the session screen's state (header status,
composer gating, the permission card), the auth state machine with persistence across a "killed" process and the
built-in relay, token refresh and revocation, the delayed connection state, and the engine against the demo relay
(paging, commands, devices, optimistic reorders and taking a refused one back, loading a listed session's history,
prompts / Stop / info for a session nobody runs, answering a permission request, new sessions, model and thinking-level
changes, slash commands), the composer commands and argument matching, the session view model (a new session turning
into the session, `/model` / `/think` cards, commands sent as prompts), and staying connected (`StayingConnectedTest`,
`EngineReconnectTest`: a dead socket replaced after coming back to the foreground or a network change, a live one kept,
the 20 s watchdog, `UNAUTHENTICATED` and its back-off, `REVOKED`, a mutation moved to the new client, the title states)
on virtual time.
`ReorderDragTest` drags Reorder mode's handles with touch input under Robolectric.

### Screenshot tests

`ScreenshotTest` renders the main screens on the JVM with Robolectric native graphics and
[Roborazzi](https://github.com/takahirom/roborazzi), from the demo data, in light, dark and other languages:

```sh
./gradlew :app:recordRoborazziDebug --tests '*ScreenshotTest*'   # → app/build/outputs/roborazzi/*.png
```

`MarkdownScreenshotTest` renders the showcase session on a phone-wide window tall enough for the whole reply (light
and dark, `30-` / `31-markdown-*.png`) and replies cut off mid-stream plus an inline formula too wide for the line
(`32-markdown-streaming.png`).

### Relay integration test

`RelayIntegrationTest` signs a phone in against a running relay with the app's own `AuthController`, `TokenManager`
and HTTP client, links a "computer" on the same account that mirrors a session through the bridge functions, and
decodes `sessions:list/groups/get/events` (including paging with `endCursor`), `sessions:reorderSessions/resetOrder`,
`commands:*`, `devices:list`, `users:me` and
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
  data/        wire models, RelayJson (float64 ↔ Long), errors, Convex HTTP API, Keystore box, settings/drafts/cache/collapsed projects
  engine/      CrokEngine (per-account facades), RelayConnection (staying connected), RelayTransport + ConvexTransport,
               TranscriptPager, ConnectionState (+ NetworkMonitor, AppForeground)
  demo/        DemoData + DemoTransport (in-memory relay for demo mode and screenshots)
  logic/       pure logic: Transcript, ComposerCommands (command list, matching, bot cards), Markdown, MathExtractor,
               SyntaxHighlighter, RevealPacer, SessionList (sections), SessionOrder, PlanSummary, RelativeTime, UserCode
  ui/          CrokRoot (navigation), theme, common components, signin/, sessions/, session/, settings/
```

## Telegram patterns

Structure and UX only — Telegram is GPL and no code is copied. See the full table in `relay/DESIGN.md` §5.

| pattern | here |
|---|---|
| AccountInstance / engine facade, torn down on sign-out | `CrokEngine` (`sessions`, `events`, `commands`, `devices`, `accounts`), created and closed by `AppViewModel` |
| LoginActivity's persisted pages | `AuthController` + `AuthStore` (welcome → waiting → signed in; resumes after a kill) |
| Connection state in the title, 0.3 s delayed | `ConnectionTitle` + `delayedForDisplay()` ("Waiting for network" / "Connecting…" / "Updating…") |
| DialogCell, FilterTabsView | `SessionRowItem` (avatar + online dot, time, folder, preview / working… / Needs approval, badge, pin) under project sections, filter tabs |
| Swipe actions, list frozen during a swipe | `SwipeToDismissBox` (pin / archive), `SessionList.freezeOrder` |
| ChatActivity reversed, windowed history | `LazyColumn(reverseLayout = true)` over `TranscriptPager` (50 per page, `endCursor` pinning) |
| Grouping, day headers, status ticks, failed-message menu | `Transcript.build`, `TranscriptViews` (clock → ✓ → ✓✓, red "!" with Retry / Delete) |
| Streaming-stop send button, blocked when offline | `Composer` (Send / Stop / offline note) |
| Bot menu button, command list, inline keyboards | `MenuPill`, `CommandList`, `BotCardRow` |
| New chat (compose → pick → empty chat) | compose button → `ProjectPicker` → new-session screen (`NewSessionRoute`) |
| TextRevealController | `RevealPacer` + `rememberRevealedLength` |
| Pinned message bar, page-down button with counter | `PlanBar`, `ScrollToBottomButton` |
| SessionsActivity (active sessions), QR login | `DevicesScreen`, `LinkComputerScreen` (Google code scanner) |
| Theme.java semantic keys | `CrokColors` (`ui/theme/Theme.kt`) |

## Not verified here

Everything that needs a device or emulator: the Convex WebSocket client (its Rust core loads through JNA on Android
only; the transport is compile-checked and the same calls are verified over the HTTP API), the Auth Tab / Custom Tab
round trip, the Keystore, the Google code scanner, notifications of network changes, and the release build on a phone.
Staying connected is proven on the JVM with fake transports and virtual time, not yet on a phone that dozed or changed
networks; replacing a client destroys its native core, which only a device exercises. Liquid Glass is rendered by
Robolectric's native graphics in the screenshot tests (blur, lens, rim); its cost while scrolling on a real phone is
unmeasured.
