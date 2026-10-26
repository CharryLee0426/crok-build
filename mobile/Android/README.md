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

Nobody types the relay's address: like crok itself, the app has it built in, and the sign-in screens have no server
field. `BuildConfig.RELAY_URL` comes from the `CONVEX_URL` line of `relay/environments/<env>.env`
(`app/build.gradle.kts`):

| Build type | Relay | Environment file |
|---|---|---|
| debug | development, `https://limitless-badger-727.convex.cloud` | `relay/environments/dev.env` |
| release | production, `https://tacit-finch-29.convex.cloud` | `relay/environments/prod.env` |

- `-PcrokRelayEnv=prod|dev` (or `crokRelayEnv` in `gradle.properties`) picks one environment for both build types.
- `mobile/scripts/build-apps.sh prod` builds the release APK on the production relay and puts it on the Desktop as
  `crok-android-prod.apk`; `mobile/scripts/build-apps.sh test` builds the debug APK on the development relay as
  `crok-android-debug.apk` (both in `~/Desktop/Crok mobile e2e builds/`).
- Development only: `./gradlew :app:assembleDebug -PcrokRelayUrl=http://10.0.2.2:3210` (the emulator's alias for the
  host's `npx convex dev`), or `crokRelayUrl` in `gradle.properties`. It wins over the environment. The build refuses a
  value that is not an `http(s)://host[:port]` URL.
- Debug builds allow plain HTTP only to `10.0.2.2`, `127.0.0.1` and `localhost` (`src/debug/res/xml/
  network_security_config.xml`); release builds are HTTPS only.
- A sign-in belongs to the relay that issued it (stored with its credentials). A build that
  finds a sign-in from another relay, such as a release build installed over a debug one, forgets it at start and asks
  to sign in again ("This build uses a different relay").

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

## Computers, projects and sessions

As on iOS ([`mobile/DESIGN.md`](../DESIGN.md)): Telegram's accounts, groups with topics and topics. Every session on
every linked computer — also the ones no crok runs right now, listed from the computer's disk — in an order the person
sets and every client shares.

- Each linked computer is an **account** of the person. The Sessions tab shows only the selected one
  (`ComputerSelectionStore`, `crok.selectedComputer`; by default the most recently active). The **computer switcher**
  (long press on the Profile tab, or the Sessions title) lists them in link order with their unread counts and a
  checkmark, then **Link a computer**; Profile lists them too. Switching takes the Sessions tab back to its root.
- The Sessions tab's rows are the computer's **projects** as Telegram's forum rows (`SessionsScreen`): a rounded-square
  avatar, the name and time, the three most recent sessions' titles with their topic glyphs, then "working…" / "Needs
  approval" / the latest preview, and the unread total. Above them, **Archived Sessions** (that computer's archived
  sessions). A swipe from the start marks a project read. Search lists the computer's matching sessions.
- A project opens its **topics** (`ProjectScreen`): one row per session with its topic glyph (a speech bubble in one of
  Telegram's six topic colours, picked from the session id with the same FNV-1a hash as iOS), the folder line only
  when it is not the project's, two lines of preview; swipes Pin / Archive; a long press has Stop, Mark as Read, Move up
  / Move down. Its "⋯" menu has Mark All as Read, Reorder and Sort by recent activity.
- **Edit** (Sessions tab) gives projects drag handles, and the tab bar gives way to **Read All** and **Sort by recent
  activity**; a project's **Reorder** does the same for its sessions (pinned ones stay first). Moves are optimistic:
  `CrokEngine` shows them at once and drops its local copy once `sessions:groups` reflects them, or takes them back if
  the relay refuses.
- **Mark All as Read** (long press on the Sessions tab, Read All, a project's Read) calls `sessions:markRead` for each
  unread session; `CrokEngine` shows them read at once and takes back the ones the relay refused.
- The session screen's top-right button is the session's topic glyph (it opens the info sheet); its background and the
  person's bubbles follow the **session theme** (Profile › Appearance: Telegram's chat themes drawn as a four-colour
  gradient with Material-icon doodles, light and dark variants, or a photo from the system photo picker, optionally
  blurred and dimmed in dark mode; `ui/theme/SessionThemes.kt`).
- Debug builds wear a yellow launcher icon (`src/debug/res/values/colors.xml`), release builds the blue one.
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

- Each project of an online computer has **New session** in its long-press menu and its screen's compose button; the top bar's
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
- **Model and thinking level** ([`mobile/DESIGN.md`](../DESIGN.md)): above the field, on the new-session screen and in
  every session, a setup row of two glass pills — the model (chip glyph, name truncated in the middle, "Default" until
  one is picked in a new session) and, when the model has levels, the thinking level (brain glyph). The list is the
  computer's own (`devices:models`, its own subscription; `sessions:get` → `models` only when that query fails on an
  older relay). The model pill opens **Choose a Model** (a bottom sheet: search over name, id and description, sections
  by provider, the current one ✓); the thinking pill a glass menu above the composer. In a session a pick calls
  `commands:setConfig` (the pill shows the new value with a spinner until `commands:get` says done, a snackbar on
  failure); in a new session it goes with the first prompt (`sessions:create`'s `model` / `effort`). Hidden while the
  computer is offline, while the session is starting and while the command list is open; dimmed (a tap says why) when
  the computer's crok offers no list. Session info's Model and Thinking level rows open the same pickers.
- `/model` and `/think` answer with a local **bot card** in the transcript and an inline keyboard (the same list as the
  pills; the current choice marked ✓; thinking levels two per row). A tap calls `commands:setConfig` and spins until
  `commands:get` says done; the card then reads "Model: Grok 4 ✓". With an argument they match by id, level or name
  (exact first, else a unique prefix) and apply directly. Without a list the card says the computer is offline, or —
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

## o11y (debug builds)

As mobile/DESIGN.md "o11y" describes, and as the iOS app does: debug builds (`BuildConfig.O11Y_TAB`) have a third
tab, **o11y**, right of Profile, with the relay owner's Grafana Cloud stack as pages the relay builds (relay/DESIGN.md
§3 "o11y"). Each screen subscribes to `o11y:page` and calls the `o11y:refresh` action (`RelayTransport.action`) when
its page is missing or older than 90 s, every 60 s while shown, and on pull to refresh; the range picked is kept per
page. The app only draws blocks: a stats grid (2 columns upright, 4 on a wide screen), time charts drawn on a Canvas
with the same marks as iOS (a tap or a hold-and-drag shows a callout; a swipe that starts on a chart scrolls the page),
ranked rows, lists and link rows; wide screens put stats and charts across and pair the rest. Models in `data/O11y.kt`,
the number rules and layout in `logic/O11y.kt`, the screens in `ui/o11y/`, the demo pages in `demo/DemoO11y.kt` over
`app/src/debug/assets/o11y-demo.json` (made by `relay/scripts/o11y-demo.mjs`; release builds carry no demo pages).

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
no models and cannot start sessions), the model and thinking pills (the MacBook lists its own models, DeepSeek's and
OpenRouter's), `/model` and `/think` and device sign-outs all work against the in-memory relay
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
changes, a computer's `devices:models`, slash commands), the composer commands and argument matching, the model
pickers (`ModelSetupTest`: provider sections, search, the pills' labels, Default, hidden / dimmed / busy rules, the
`devices:models` fallback), the session view model (a new session turning into the session and sending its picked
model and level, setup-row changes and refusals, `/model` / `/think` cards, commands sent as prompts), and staying
connected (`StayingConnectedTest`,
`EngineReconnectTest`: a dead socket replaced after coming back to the foreground or a network change, a live one kept,
the 20 s watchdog, `UNAUTHENTICATED` and its back-off, `REVOKED`, a mutation moved to the new client, the title states)
on virtual time.
`ReorderDragTest` drags Reorder mode's handles with touch input under Robolectric.
`TranscriptBottomTest` opens the showcase session on a phone-sized window (its reply is taller than the screen): it opens
on the reply's end, a short scroll up inside the reply brings the scroll-to-bottom button and the button goes back to the
end, new items are followed from the end and counted (the reader left in place) from inside the reply.

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
  demo/        DemoData + DemoTransport (in-memory relay for demo mode and screenshots), DemoO11y (the o11y pages)
  logic/       pure logic: Transcript, ComposerCommands (command list, matching, bot cards), Markdown, MathExtractor,
               SyntaxHighlighter, RevealPacer, SessionList (sections), SessionOrder, PlanSummary, RelativeTime, UserCode
  ui/          CrokRoot (navigation), theme, common components, signin/, sessions/, session/, settings/, o11y/
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
