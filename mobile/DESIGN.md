# Phone apps: computers as accounts, projects as groups, sessions as topics

Status: 2026-10-23. This is the contract both phone apps (`mobile/iOS`, `mobile/Android`) and, since 2026-10-23, the
web app (`relay/app`, section "Web") implement, so they look and work the same. It replaces relay/DESIGN.md §5 "The
session list" (tabs All / per computer / Archived, one section per project). Everything else in relay/DESIGN.md §5 (the session
screen, the composer, Markdown, Look, Staying connected) still holds. No relay change: every call below already exists.

The model is Telegram's: one person (the relay account) with several **accounts** under it, one per linked
**computer**. The Sessions tab shows only the selected computer, like Telegram shows only the current account. On a
computer, each **project** is a **group with topics** (Telegram's forum), and each **session** is a **topic** in it.

| crok | Telegram | where |
|---|---|---|
| relay account (Clerk user: name, email, picture) | you | Profile header, Profile tab icon |
| a linked computer | an account (long-press the Settings tab, "Add Account") | computer switcher, Profile's computer list |
| a project on that computer | a group with topics (forum) | Sessions tab rows |
| a session in the project | a topic | project screen rows, session screen |
| archived sessions of that computer | Archived Chats | first row of the Sessions tab |

## Tabs

Two tabs: **Sessions** and **Profile** (it was "Settings").

- Sessions: the chat-bubbles icon; badge = unread on the selected computer.
- Profile: the icon is the relay account's picture (`users:me().imageUrl`, else initials on the accent gradient), a
  circle about 28 pt/dp; selected, it gets a 2 pt accent ring. Label "Profile". Badge = unread on the other computers
  (Telegram shows the other accounts' unread there).
- **Long press Sessions** → a menu with **Mark All as Read** (every unread session of the selected computer,
  `sessions:markRead` for each, shown read at once); disabled when nothing is unread.
- **Long press Profile** → the **computer switcher** (below).

## The computer switcher

A menu (iOS: the system context menu from the tab bar; Android: a glass popup above the tab bar) listing every
computer in link order (`devices:list` `createdAt` ascending, then computers only known from `sessions:groups`):
computer avatar, name, and "N unread" or its status as the second line, a checkmark on the selected one; then, in its
own section, **Link a computer** (plus icon), which opens the QR scanner. Picking a computer selects it and returns
the Sessions tab to its root. The same menu opens from the Sessions tab's title.

The selected computer is remembered on the phone (`crok.selectedComputer`). With none remembered, or once it is gone,
the one with the most recent session activity is selected, else the first.

**Computer avatar**: a circle with the computer name's initials (same rule as project initials) on a colour from the
avatar palette keyed by the device id, with the green online dot while online.

## Sessions tab (the selected computer)

- **Top bar**: leading **Edit**; title = the computer's name with a small chevron (tap: the switcher); subtitle =
  "Online" in the accent colour, or "last seen …" (existing string), replaced by the connection state ("Connecting…",
  "Updating…", "Waiting for network") while the relay is not live; trailing: compose (new session: pick one of this
  computer's projects; nothing to pick while the computer is offline).
- **Search** (pulled down, "Search sessions"): this computer's sessions whose title, folder, project, preview or model
  match, as flat topic rows with the project name on their second line.
- **First row, Archived Sessions** (when the computer has archived sessions and no search is on): a grey circle with
  an archive box, title "Archived Sessions", second line the archived titles joined by ", ". Tap: the Archived
  screen.
- **One row per project** (a forum row), in the relay's order (`sessions:groups` kept to this computer):
  - Avatar: a **rounded square** (corner radius 30 % of the side, Telegram's forum avatar), 54 pt/dp, project initials
    on the project colour; desaturated and dimmed while the computer is offline.
  - Line 1: project name (semibold) · last activity time (accent while unread).
  - Line 2, the topics: up to three session titles, most recently active first, each after a small topic icon
    (12 pt/dp): the first in the primary colour, the others secondary, separated by two spaces.
  - Line 3: "working…" (animated) while any of its sessions runs, else "Needs approval" while one waits, else the
    most recent session's preview ("You: " prefix for a prompt, tool and error glyphs as before), else "No messages
    yet". Trailing: the project's unread total (grey while offline).
  - Tap: the project screen. Leading swipe: **Read** (when unread). Long press: New Session, Mark as Read, Move Up,
    Move Down, Sort by Recent Activity (its sessions).
- **Edit** mode: drag handles move projects (`sessions:reorderProjects` with this computer's keys). The tab bar gives
  way to a bottom toolbar: **Read All** (left) and **Sort by Recent Activity** (right, `resetOrder({})`). **Done**
  ends it. Search turns Edit off.
- Empty: no computer at all → "No computers yet", "On your computer, run crok remote login (or open Crok Desktop ›
  Settings › Remote control). Sessions you work on there show up here." and **Link a computer**. A computer without
  sessions → "No sessions on <computer> yet" and **New Session** while it is online.

## Project screen (the group's topics)

- Top bar: title = project name, subtitle = "<n> sessions · <computer>" (or the connection state). Trailing: compose
  (New Session in this project, disabled while offline) and a "⋯" menu: Mark All as Read, Reorder, Sort by Recent
  Activity. In Reorder: **Done**.
- Search filters the project's sessions.
- **Topic rows**: the session's topic icon (40 pt/dp), title (semibold, one line) and time; a second line with the
  folder when it is not the project's and "offline" while the computer is (left out otherwise); the preview in up to
  two lines, or "Starting…" / "working…" / "Needs approval" / "History on <computer>" / "No messages yet" as before;
  trailing unread badge or pin.
- Leading swipe: Pin / Unpin. Trailing swipe: Archive, plus Stop while running. Long press: Pin, Stop, Mark as Read,
  Archive, Move Up, Move Down.
- Tap: the session screen.

**Topic icon** (Telegram's topic glyph): a speech bubble — a circle with a short tail at the bottom left — filled with
a top-to-bottom gradient of the topic colour, the title's first letter (uppercased, `·` when none) in white, bold
rounded. Colour from Telegram's six topic colours, keyed by the session's doc id (FNV-1a, as `ProjectAvatar`):
`#6FB9F0` blue, `#FFD67E` yellow, `#CB86DB` violet, `#8EEE98` green, `#FF93B2` rose, `#FB6F5F` red (gradient from the
colour lightened 15 % at the top to the colour at the bottom).

## Archived screen

Title "Archived Sessions", subtitle the computer. This computer's archived sessions (`sessions:list({archived:true})`
kept to it) as topic rows with the project name on the second line. Trailing swipe and long press: **Unarchive**.
Empty: "No archived sessions", "Swipe left on a session to archive it."

## Session screen

As before, plus: the trailing top-bar button is the session's topic icon (32 pt/dp; tap: session info), where
Telegram shows the chat's avatar; the background and the person's bubbles follow the session theme (below). The
new-session screen uses the same background.

The transcript loads as a window of live parts (relay/DESIGN.md §3 "Loading long transcripts", `sessions:transcript`),
so a session with thousands of turns opens on its newest 40 items and a streamed reply re-sends only the live end.
Sending a prompt (also a new session's first) keeps the transcript's end in sight whatever its length: a transcript
shorter than the screen sits at the bottom above the composer, never scrolled away from it.

### Thinking and tool calls

After Crok Desktop's reasoning and tool rows (`desktop/macOS/…/TranscriptRowViews.swift`, `ThinkingEffects.swift`), but
**status only**: the phones never show a thought's text or a tool's output (the relay does not send them), so nothing
expands. Both sit on the agent's side like its bubbles (28 pt/dp kept free on the right) and draw on the theme's card
fill (`Theme.card` / `colors.card`: white at 75 % / `#1D1E1D`), which reads on Crok Day and Night, every session theme
and a photo alike; the state tints go on top of that fill.

**Thinking** — a compact card hugging its content (radius 12, padding 12 × 8): the `sparkle` glyph (13 pt/dp), 8 gap,
the label (15 pt/sp medium, one line).
- Active (the transcript's newest event while the turn runs, i.e. the session's status is `running` or `waiting`):
  "Thinking…". Label and glyph are filled with Desktop's thinking colours
  `#598CFF → #9E6BFF → #FA66B8 → #FF9E52 → #FA66B8 → #9E6BFF → #598CFF` sliding sideways (one sweep per 2.4 s); the
  glyph turns once per 2.8 s; a 2 pt/dp bar runs along the card's bottom (inset 12): a track of the secondary text
  colour at 14 %, and a segment 36 % of its width with the same colours sliding end to end and back over 1.25 s.
  Reduce Motion / animations off: the colours stand still, the glyph does not turn, the segment fills the bar.
- Done: "Thought", glyph and label in the secondary text colour, no bar.

**Tool call** — a card as wide as the agent's column (radius 12, height ≥ 44 pt/dp, padding 12 × 10): a 16 pt/dp
status glyph, 10 gap, the title (15 pt/sp, one line, middle of a long one elided at the end; `` `code` `` spans in
the monospaced font on the code-span fill, as Desktop does for `` Execute `git status` ``), then the status word
(12 pt/sp) at the trailing edge.

| state | when | glyph | status word | card |
|---|---|---|---|---|
| running | `pending` / `in_progress` while the turn runs (`running` / `waiting`) and the call is part of it (after its prompt and after the last turn-end marker) | spinner: a 13 pt/dp ring (1.8 line, 20 % of the tint) with a 68 % arc turning once per 0.9 s, executing blue `#2868E8` / `#5FA8FF` | "running", blue | card fill + a 1 pt/dp rim in blues `#3366FF → #1A9EFF → #47DBFA` sliding sideways (static with Reduce Motion) |
| completed | `completed` | `checkmark.circle.fill`, green `#3B7751` / `#91C5A1` | "done", green | card fill + green at 10 %, 1 pt/dp border green at 35 % |
| failed | `failed` | `xmark.circle.fill`, red `#B3261E` / `#F2877E` | "failed", red | card fill + red at 10 %, 1 pt/dp border red at 40 % |
| stopped | `pending` / `in_progress` otherwise (its turn ended or was stopped) | the kind's glyph (below), secondary | "stopped", secondary | card fill + hairline |
| other | any other status | the kind's glyph, secondary | none | card fill + hairline |

Kind glyphs (SF Symbols; Android: the matching Material icons): read `doc.text`, edit `pencil`, delete `trash`, move
`arrow.left.arrow.right`, search `magnifyingglass`, execute `terminal`, think `brain`, fetch `globe`, other
`wrench.and.screwdriver`. A long press offers Copy (the title). No grouping: each call is its own card, as on Desktop.
Words (6 languages): "Thinking…", "Thought", "running", "done", "failed", "stopped".

## Model and thinking level

Added 2026-10-23. A session's model and thinking level can be seen and changed where the person writes, before a new
session starts and at any time after, from the choices of the computer it runs on: what Crok Desktop's composer pickers
and the web's pills do. `/model` and `/think` (bot cards) stay as they are and use the same list.

**The list.** `devices:models({deviceId})` for the session's computer (or the new session's), subscribed while the
screen is open; it changes only when that computer's list changes. A computer with OpenRouter signed in lists about
500 models; the relay sends them in picker order (the computer's default, its own providers, then OpenRouter).
`sessions:get`'s `models` is the fallback only when `devices:models` fails (an older relay without the query); it is
null for lists over 200. The session's current choice is `sessions:get`'s `model` and `effort` (the level: the effort
whose `value ?? id` equals it). The bot cards read the same list.

**The setup row.** In the composer bar, above the input row (below the permission card; hidden while the command list
is open), left-aligned with 8 pt/dp between: two pills, 30 pt/dp high, capsule, the session palette's service
background at the bar's level (iOS: `glassSurface` on 26, a tinted capsule before; Android: the bar's glass tint)
with primary text in the footnote / `labelMedium` style. Not accent-filled: the Menu pill is the accent one.

- **Model pill**: a chip glyph (iOS `cpu`, Android `Memory`), the model's `name` (else its id) truncated in the middle
  (max about 60 % of the row), a small down chevron. In a new session it says **Default** until one is picked.
- **Thinking pill**: a brain glyph (iOS `brain`, Android `Psychology`), the level's `name`, a chevron. Shown only when
  the model has `efforts` (in a new session: only once a model with levels is picked; "Default" hides it, as the
  web does). In a new session it says **Default** until one is picked.
- While a change is on its way (`commands:setConfig` until `commands:get` says `done`), the pill shows the new value
  with a small spinner in place of the chevron and ignores taps; on `failed` it goes back to the old value and an
  alert (iOS) / snackbar (Android) says "Couldn't change the model" or "Couldn't change the thinking level" with the
  command's `error`.
- Hidden while the computer is offline (the composer shows its offline notice instead) and while the session is
  `starting` (it already carries its choice). While the computer is online but has no list (`devices:models` null:
  an older crok there), the model pill shows the session's model, dimmed, and a tap says the existing "%@ doesn't
  offer model choices yet. Update crok there." (alert / snackbar). A session without a model name and without a
  list shows no row.

**Choose a Model** (tap the model pill, or Session info › Model):

- iOS: a `.sheet` with a `NavigationStack` (title "Choose a Model", inline; leading **Cancel**), a `List`
  (`.insetGrouped`) with `.searchable(prompt: "Search models or providers")`, `.presentationDetents([.medium,
  .large])`. Android: a `ModalBottomSheet` (`colors.sheet`) with the title, a search field under it (the app's
  transparent `TextField` style with a search icon and clear button) and a `LazyColumn`.
- Sections by provider: the id up to its first `/` (`anthropic`, `deepseek`, `openrouter`…) as the section header in
  the order the providers first appear; ids without a `/` go in a section named after the computer. In a new
  session a first section-less row **Default** with "%@'s own choice" (the computer's name) under it.
- Row: the name (body; semibold when current), the id under it (caption, secondary, monospaced) when it differs from
  the name, the description (caption, secondary, at most 2 lines); a checkmark (accent) on the current one. 
- Search: case-insensitive substring of name, id or description; sections without matches hide; "No Results" when
  nothing matches.
- Footer (existing session only, under the last section): "Model changes apply to your next message."
- Tap: the sheet closes. In a session: `commands:setConfig({configId: "model", value: id})` (see the pill). In a new
  session: the choice is kept, and the thinking choice goes back to Default.

**Thinking level** (tap the thinking pill, or Session info › Thinking level): a small menu anchored to the pill —
iOS the system `Menu` with an inline `Picker` (checkmark on the current one), Android the glass popup
(`GlassMenuOverlay` with `GlassMenuRow`s, a checkmark on the current one) above the composer. Items: the model's
efforts in order by `name` (with the description as the second line when there is one); in a new session **Default**
first. Tap: in a session `commands:setConfig({configId: "reasoning_effort", value: effort.id})`; in a new session the
choice is kept.

**New session**: `sessions:create` gets `model` (the id) and `effort` (the option id) when picked; Default leaves them
out. The choice lives on the screen until it is sent (not stored).

**Session info**: the Model row shows the model's name (else the id) and the Thinking level row the level's name; both
get a chevron and open the sheet / menu above while the computer offers choices, and stay plain text otherwise.

**Demo mode**: `devices:models` answers from the demo world's per-computer lists (null for an offline computer and
for the "older crok" one), and the demo `sessions:create` applies the `model` / `effort` it is given.

## Profile

Title **Profile**. Telegram's Settings layout, with coloured square row icons (iOS 29 pt corner 7; Android the
existing `IconBadge`):

1. Header, centred: the account picture (96 pt/dp), the name (bold, title size), the email (secondary).
2. **Computers** (no header, no footer): every computer as a row — computer avatar (32 pt/dp), name, "Online" (accent)
   or "last seen …" under it, trailing its unread badge and a checkmark on the selected one; tap selects it. Last row:
   **Link a computer** with an accent plus and accent text (Telegram's "Add Account").
3. **Devices** (orange `#F09A37`, laptop-and-phone glyph, trailing the count) → Devices; **Appearance** (blue
   `#3D8BF2`, paintbrush) → Appearance; **Language** (purple `#A65EEB`, globe, trailing the current language) → the
   system's per-app language settings. No footer.
4. **Version** (grey `#8E8E93`, info glyph, trailing the version); **Contact the developer on GitHub** (black
   `#24292F` square with the GitHub mark) → https://github.com/CharryLee0426; **Contact the developer on X** (black
   `#000000` square with the X logo) → https://x.com/CharryLee426. Both open in the system browser; the URLs are not
   shown. In demo mode a "Mode · Demo" row stays. No server and no "this device" rows.
5. **Sign Out** (red).

Devices: no footer under "Sign out all other devices". Profile shows no footer under "Link a computer".

Logos (Simple Icons, CC0; 24 × 24 viewBox), drawn as white template glyphs:

- GitHub: `M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12`
- X: `M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 3.24H4.298Z`

## Appearance (Telegram's Settings › Appearance)

1. **Preview**: a card (about 190 pt/dp high, rounded 16) showing the session background with an agent bubble "All
   214 tests pass. Want me to open a PR?" and the person's bubble "Yes, please." with time and ✓✓, in the theme's
   colours.
2. **Session Theme**: a horizontal strip of theme cards (about 84 × 116, rounded 12): the theme's background with two
   mini bubbles (incoming left, outgoing right) and, at the bottom, the theme's emoji (No Theme: ✕ glyph; Photo: a
   photo glyph) — the name is the card's accessibility label and shows under the strip for the selected one. The
   selected card has a 2 pt accent ring outside a 2 pt gap. Cards draw the variant of the current light/dark mode.
   Order: No Theme, Classic, the nine emoji themes, then Photo (only once a photo was chosen).
3. **Choose a Photo** (photo picker, no permission prompt: iOS `PhotosPicker`, Android Photo Picker): the photo is
   downscaled (longest side 2048 px), stored in the app's own files, and becomes the selected Photo theme. While the
   Photo theme is selected: **Blur** (switch).
4. **Color Mode**: System / Light / Dark (the old Appearance setting, same storage).

Stored on the phone: `crok.sessionTheme` (theme id, default `none`), `crok.sessionThemeBlur` (bool).

## Session themes

Telegram's chat themes, drawn by Crok (no Telegram assets): each has a light and a dark variant. A theme sets the
session background and the person's bubbles; agent bubbles, cards and the accent stay as they are.

Background, per variant:

- **Gradient**: four colours `c0…c3` at the points (0.80, 0.10), (0.20, 0.30), (0.75, 0.65), (0.25, 0.90) of the unit
  square (x right, y down); each pixel mixes them with weights `max(0, 0.9 − distance)⁴` (normalised). Render it
  small (about 48 × 64 px) and scale it up smoothly to fill.
- **Pattern**: the theme's doodle glyphs (iOS SF Symbols, Android Material Icons, outlined, same subjects) on a
  jittered grid: cells of 62 pt/dp, glyph size 22–30 pt/dp, rotation −25…25°, jitter ±12 pt/dp, from a random
  generator seeded with the theme id (so it never moves between launches), covering the whole view.
  - Light: the gradient, then the glyphs in black at 12 % opacity.
  - Dark (Telegram's night patterns): a near-black base `#0B0D10`, the gradient over it at 18 % opacity, then the
    glyphs filled with the gradient itself at 55 % opacity (the pattern glows in the theme's colours).
- **Service capsules** on a themed background (day headers, notices): black at 22 % (light) / 40 % (dark) with white
  text, instead of the plain ones.

Bubbles: `out` = the person's bubble, `outText` its text, `outMeta` its time and ticks.

| id | name | emoji | light c0, c1, c2, c3 | light out / outText / outMeta | dark c0, c1, c2, c3 | dark out / outText / outMeta | glyphs |
|---|---|---|---|---|---|---|---|
| `none` | No Theme | ✕ | plain Crok Day `#EEEEEE` | default | plain Crok Night `#141414` | default | none |
| `classic` | Classic | 🌿 | `#DBDDBB` `#6BA587` `#D5D88D` `#88B884` | `#EFFDDE` / `#000000` / `#4FAE4E` | `#2E5B46` `#14322A` `#3F6A3A` `#1D4236` | `#2F5D50` / `#FFFFFF` / `#A5E0C9` | terminal, code, braces, chip, bug, hammer, number sign, function, keyboard, server, bolt, paper plane, cloud, sparkles, laptop, coffee |
| `home` | Home | 🏠 | `#F9D9A9` `#F2B880` `#FCE8C8` `#E9A877` | `#FFE3C2` / `#000000` / `#C4772F` | `#6B4220` `#3A2412` `#7D5026` `#4C2E17` | `#7A4A22` / `#FFFFFF` / `#F5C99A` | house, sofa, lamp, cup, key, leaf, bed, fork and knife, pan, fireplace, sun, heart |
| `duck` | Duckling | 🐥 | `#FFF3A3` `#D9F29B` `#FFE07A` `#BFE59A` | `#FFF4B8` / `#000000` / `#B89A00` | `#5E5A1A` `#33461F` `#6E5E14` `#2C3F1D` | `#6B5E12` / `#FFFFFF` / `#F2E38A` | bird, leaf, sun, cloud, drop, carrot, ladybug, tortoise, hare, flower, star |
| `snowman` | Snowman | ⛄ | `#E3F2FF` `#B8DCFB` `#F2F8FF` `#A8CDF2` | `#D8EEFF` / `#000000` / `#3390EC` | `#1E3D63` `#11233B` `#2A4B78` `#173052` | `#24507E` / `#FFFFFF` / `#A8CCF7` | snowflake, snow cloud, mountains, wind, star, moon and stars, thermometer, sparkles, cup, skier |
| `diamond` | Diamond | 💎 | `#A8E6E2` `#9AC7F5` `#C9F0E4` `#B6B4F2` | `#D4F4EE` / `#000000` / `#1F9C8F` | `#16595C` `#153562` `#1F5E57` `#353070` | `#1E6B6B` / `#FFFFFF` / `#9FEDE2` | diamond, sparkle, crown, seal, star, rhombus, hexagon, octagon, sparkles, suit diamond |
| `teacher` | Teacher | 👨‍🏫 | `#CFE8C9` `#9FD3C7` `#E7F0C3` `#B4D9A6` | `#E3F4D9` / `#000000` / `#4C9A4A` | `#2B4D35` `#1A3628` `#3E5832` `#22473F` | `#2E5A38` / `#FFFFFF` / `#B4E3A8` | book, pencil, graduation cap, ruler, function, atom, globe, backpack, paperclip, light bulb, books |
| `tulip` | Tulip | 🌷 | `#FFD1DC` `#F7A8C4` `#FFE4EC` `#F2B6D0` | `#FFDDE7` / `#000000` / `#D9467A` | `#6E2447` `#43162D` `#852E55` `#561D38` | `#7A2A4E` / `#FFFFFF` / `#FFB3CE` | flower, leaf, heart, sun, ladybug, drop, sparkles, pollen, cloud, star |
| `purple` | Purple Heart | 💜 | `#E2D4FA` `#C7B2F2` `#F0E6FF` `#D5B8EE` | `#EADFFF` / `#000000` / `#8A5CD8` | `#45276F` `#29184B` `#5A318C` `#371F60` | `#563590` / `#FFFFFF` / `#D3BCFF` | heart, sparkles, star, moon, music note, suit heart, balloon, gift, envelope, smile |
| `christmas` | Christmas Tree | 🎄 | `#D7EBD3` `#F3D8C5` `#C3E0C9` `#F1E3B3` | `#E2F2DC` / `#000000` / `#3D8E48` | `#1D472D` `#572222` `#173A24` `#4C3A15` | `#2D5C3A` / `#FFFFFF` / `#B5E6BE` | gift, snowflake, star, bell, tree, flame, sparkles, moon and stars, cup, music note |
| `game` | Video Game | 🎮 | `#C9D6FF` `#E2C9FF` `#B8F0FF` `#D6E4FF` | `#DDE4FF` / `#000000` / `#5B6CF0` | `#272E73` `#451E77` `#17456F` `#33216F` | `#3B3F9E` / `#FFFFFF` / `#C3C8FF` | game controller, arcade stick, d-pad, trophy, bolt, star, checkered flag, heart, puzzle piece, die, crown, keyboard |
| `photo` | Photo | 🖼 | the chosen photo, filling the view (cropped), blurred (radius 24) when Blur is on | default | the same photo under black at 40 % | default | none |

## Web (`relay/app`)

Added 2026-10-23: the web app follows this contract too, laid out like Telegram Web (web.telegram.org/a) instead of
tabs. Same relay calls, same words, same behaviour; only the gestures and the frame change.

**Frame.** From 1024 px wide: a **left column** (380 px, its own scroll) and the **middle** (the session); the
**right column** (session info, 360 px) opens beside the middle from the session header and closes with its ✕. Below
1024 px one column at a time, as on a phone: the left column fills the window and the session slides over it (with a
back button); session info is a full-height panel over the session.

**Left column.** It is a stack of pages, like Telegram Web's left column (a page slides in from the right, its header
has a back arrow):

- **Root: the selected computer's Sessions.** Header: the **computer switcher** button on the left — the computer
  avatar (36 px, online dot), the computer's name (semibold) with a small chevron, and under it "Online" (accent),
  "last seen …" or the connection state ("Connecting…", "Updating…", "Waiting for network"); a click opens the
  switcher as a dropdown (the phone menu's items: every computer with avatar, name, "N unread" or its status, a check
  on the selected one; then **Link a computer** → `/link`). On the right: **Edit**, compose (New Session: the
  project picker for this computer; disabled while it is offline) and the **Profile** button (the account picture,
  32 px, with the other computers' unread badge). Under the header the search field "Search sessions".
  Rows as on the phones: Archived Sessions, then one forum row per project (rounded-square avatar 54 px, three lines,
  unread badge). Hover shows a ⋯ button; it and a right click open the long-press menu (New Session, Mark as Read,
  Move Up, Move Down, Sort by Recent Activity). Edit mode: drag handles (pointer drag, the existing reorder code) and a
  bottom bar with **Read All** / **Sort by Recent Activity**, **Done** in the header. Empty states as on the phones.
- **A project** (click a forum row): header with back, the project avatar (40 px), name and "%lld sessions · %@";
  trailing compose and a ⋯ menu (Mark All as Read, Reorder, Sort by Recent Activity). Topic rows as on the phones (topic
  icon 40 px). The phones' swipe actions are hover buttons on the row's right (Pin, Archive; Stop while running) and
  the right-click / ⋯ menu (Pin, Stop, Mark as Read, Archive, Move Up, Move Down). The open session's row is selected
  (accent background, white text, as Telegram Web).
- **Archived Sessions**: the phones' Archived screen; Unarchive on hover and in the menu.
- **Profile** (the Profile button): the phones' Profile page — header (picture 96 px, name, email), Computers (select
  one; **Link a computer**), Devices (the devices list as a page here), Appearance (a page: preview card, Session
  Theme strip, Choose a Photo, Blur, Color Mode), Language (the language list), Version (the web app's), Contact the
  developer on GitHub / X (new tab), Sign Out (red; Clerk sign-out).

**Middle.** The session as now (transcript, composer with the Menu button, bot cards, permission card), with the
phone session screen's additions: the topic icon (36 px) at the right of the header opens the right column; the
background and the person's bubbles follow the session theme; the composer has the **setup row** ("Model and thinking
level": the model dialog is a centred modal 480 px wide with the same search, sections and rows; the thinking menu a
small popover). The new-session screen is the same, with "New session", the project and computer under it, "Starts in
<path> on <computer>" and the setup row with Default. With nothing open the middle shows the theme background and
"Choose a session" (as now).

**Remembered in the browser** (localStorage, like the phones' settings): `crok.selectedComputer`, `crok.sessionTheme`,
`crok.sessionThemeBlur`, `crok.colorMode` (`system` | `light` | `dark`, sets `data-theme` on `<html>`), the photo
(downscaled to 2048 px, JPEG, in IndexedDB). The page title shows the unread total: "(3) Crok".

**Session themes** as specified above: the gradient rendered small on a canvas and scaled up; the pattern drawn on a
canvas from the theme's glyphs as inline SVG paths (the web's own outline icons for the same subjects; no Telegram or
platform assets); service capsules and bubbles from the theme's colours.

Signed-out pages (landing, sign-in), `/link` and `/devices` stay as routes; Profile links to them where it needs to.

## Dev builds

Debug builds (`mobile/scripts/build-apps.sh test`, the dev relay) carry a **yellow** icon, release builds (prod)
the blue one: the same mark on a yellow tile (`#FFD84D` → `#F6B800` top to bottom on iOS, flat `#F6B800` on
Android) with the mark in dark brown `#3D2E00`; the iOS dark variant keeps the dark tile with the mark in `#FFC933`.

## o11y (dev builds)

Added 2026-10-26. Debug builds (`build-apps.sh test`, the dev relay) have a third tab, **o11y**, to the right of
Profile: the relay owner's Grafana Cloud stack on a phone — the LLM Observability dashboards, crok's evaluation
(online evaluators, guards, offline experiments) and Agent Observability (agents, conversations, SLOs, alerts). Release
builds have no such tab. The relay reads Grafana and sends each screen as a **page** of ready-made blocks
(relay/DESIGN.md §3 "o11y"); the phones only draw pages, so both draw exactly the same thing and a new dashboard needs
no app update. The look is Telegram's channel statistics: grouped cards, a numbers grid with changes, charts with a
legend under them, ranked rows.

**Tab.** Label "o11y" (not translated: it is a numeronym), icon iOS `chart.xyaxis.line`, Android `Insights`
(outlined; filled when selected). No badge, no long-press menu. Its root is the page `home`; rows of a page push
other pages on the tab's own stack.

**Top bar.** Title = the page's `title` (inline on iOS, as Profile), subtitle = the page's `subtitle` and, after a
" · ", "Updated %@" with the relative age of `builtAt` ("Updated 2 min ago"), replaced by the connection state while
the relay is not live (as the Sessions titles). Trailing: **Open in Grafana** (iOS `safari`, Android `OpenInBrowser`)
when the page has a `url`; it opens the system browser.

**Range.** When a page offers more than one range (`ranges`), a segmented control at the top of the content
(iOS `Picker(.segmented)`, Android `SingleChoiceSegmentedButtonRow`) with the page's ranges in order, labelled
"%lldh" / "%lldd" (`1h`, `6h`, `24h`, `7d`, `14d`; translated in the Words table). The phone remembers the choice
per page (`crok.o11y.range.<page id>`, default the page's `range` as the relay first sent it).

**Loading and refresh** (relay/DESIGN.md §3):

- The screen subscribes to `o11y:page({page, range, lang})` (`lang` = the app's UI language: `en`, `zh`, `ja`, `es`,
  `fr`, `de`) and shows whatever page it holds at once, however old.
- It calls the action `o11y:refresh({page, range, lang})` when it appears with no page or a page older than
  90 seconds, and again every 60 seconds while it stays on screen and the page is older than 90 s. The new page
  arrives through the subscription.
- Pull to refresh calls `o11y:refresh({…, force: true})` and ends when the action returns.
- While a refresh runs (`refreshing`) and a page is on screen: a small spinner after the subtitle. With no page
  yet: a centred spinner and "Loading o11y…".
- `error` (the last refresh failed; an older page may still be there): a banner card at the top, red exclamation
  glyph, "Couldn't update" and the message, over the old page.
- `state: "forbidden"`: the empty state "o11y is not available" / "This account can't see the relay's Grafana
  stack. Ask whoever runs the relay to add it." `state: "unconfigured"`: "o11y is not set up" / "The relay has no
  Grafana token yet. Run relay/scripts/o11y-setup.sh on the relay owner's computer." A relay without the query (the
  call fails with "Could not find public function"): "o11y is not set up" / "This relay doesn't serve o11y yet."
  Each with the `chart.xyaxis.line` / `Insights` glyph, large and secondary, centred.

**Layout.** The page's sections in order, each a card in the grouped-list look (iOS: `secondarySystemGroupedBackground`
cards, radius 10, on `systemGroupedBackground`, 16 pt side margins plus the safe area; Android: `colors.card` on
`colors.grouped`, radius 16 as Profile's sections, the Profile list margins). A section's `title` sits above its card as a list header
(iOS footnote uppercase secondary; Android `labelLarge` in the accent, as Profile's headers), its `footer` under it
(footnote / `bodySmall` secondary).

- **Narrow** (content width < 600 pt/dp; a phone held upright): one column.
- **Wide** (≥ 600; a phone on its side, or a tablet): `stats` and `chart` sections span the width; the others
  (`ranking`, `list`, `links`, `note`, `error`) are half width, two consecutive half sections side by side (top
  aligned, 16 gap); a half section without a partner next to it spans the width. Charts are 180 pt/dp high when the
  screen is shorter than 500 (landscape phone), else 200. Rotating keeps the scroll position on the same section.

**Blocks** (one per section; values come raw with a unit and are formatted on the phone, see Numbers):

- `stats` — a grid of tiles, 2 columns narrow, 4 wide, hairline separators between them (Telegram's overview).
  Tile: the value (title3 / `titleMedium`, semibold, monospaced digits; "—" when null), then on the same line the
  `change` when there is one: "+12%" / "−8%" (caption, semibold) in green `#3B7751` / `#91C5A1` when it moved the
  `better` way, red `#B3261E` / `#F2877E` when the other way, secondary when `better` is `none`; under them the
  label (footnote / `bodySmall`, secondary, up to 2 lines). Accessibility: "label, value, up 12 percent".
- `chart` — a time chart in the card (12 inset): `style` `line` (2 pt lines, round caps; a single series also gets
  a 10 % area wash) or `bars` (≤ 24 pt/dp wide with a 2 pt gap between neighbours, 4 pt rounded top, square at the
  baseline; `stacked`: segments stacked with a 2 pt surface-coloured gap, only the top segment rounded). A series
  with `dashed: true` is a dashed line (8 on, 6 off) in the secondary text colour, drawn over the bars or lines
  (Grafana's "7 days earlier"). One y-axis at the leading edge: 4 hairline gridlines at round values from 0 (steps of
  1, 2, 2.5 or 5 × 10ⁿ), each label over its line at the leading edge, all in the unit the top one needs and without
  trailing zeros ("$0 $5 $10 $15", "0 s 25 s 50 s 75 s", "0 500 1K 1.5K"; caption2 / `labelSmall`, secondary); x-axis
  labels: 3 times on a narrow chart (< 360 pt/dp), else 4, "HH:mm" when `step` < 1 day, else "MMM d" (localized), the
  first and last flush with the plot's edges. **Colours**: series `slot` 1–8 → the categorical palette (light / dark):
  blue `#2A78D6` / `#3987E5`, orange `#EB6834` / `#D95926`, aqua `#1BAF7A` / `#199E70`, yellow `#EDA100` /
  `#C98500`, magenta `#E87BA4` / `#D55181`, green `#008300` / `#008300`, violet `#6250D6` / `#9085E9`, red
  `#E34948` / `#E66767`; slot 0 ("Other") the secondary text colour at 60 %. **Legend** (≥ 2 series): chips under
  the chart, wrapping — a 8 pt dot in the series colour, the name (caption / `labelMedium`, primary text) and its
  `total` formatted (secondary); a tap hides or shows that series (the last visible one stays), a hidden chip is
  dimmed with an outlined dot; colours never move. **Touch**: a tap on the plot shows a vertical hairline at the
  nearest point (with a dot on each line) and a callout card (radius 8, `.regularMaterial` / `colors.sheet`) with the
  time and each visible series' value at that point, largest first, with its dot; a tap on the same point hides it.
  Holding (0.25 s) then dragging moves it with the finger, and it goes on release. A plain drag scrolls the page.
  No series or every value null: "No data in this range", centred, secondary, in the chart's height. `more` > 0: a
  footer line "and %lld more" under the legend.
- `ranking` — ranked rows (Telegram's top lists): the label (body, one line, truncated in the middle), the value at
  the trailing edge (subheadline semibold, monospaced digits) with the row's `change` after it when there is one
  (coloured as a stat's), `detail` chips under the label (caption, secondary, joined with " · "), and under the row
  a 4 pt rounded bar from the leading edge, its length = value / the largest value (a `ratio` ranking: value / 1),
  in the slot-1 blue (or the row's `slot`). Row height ≥ 44. `more` > 0: a last line "and %lld more" (secondary).
  No rows: the block's `empty` text, centred, secondary.
- `list` — rows: a leading status glyph when `status` is set (`ok` checkmark.circle.fill green, `bad`
  xmark.circle.fill red, `warn` exclamationmark.triangle.fill orange `#F09A37`, `info` info.circle secondary; 18 pt),
  the title (body, one line, truncated at the end), `detail` chips (footnote / `bodySmall`, secondary, " · ", up to
  2 lines); trailing: the `value` (subheadline semibold) over the `time` (caption secondary: "HH:mm" today, "MMM d"
  before). A row with a `page` gets a chevron and pushes that page. A long press offers Copy (title and details).
  No rows: `empty`, centred, secondary.
- `links` — Profile-style rows: the coloured square icon (29 pt radius 7 on iOS, `IconBadge` on Android; colour =
  the row's `color`, glyph from its `icon`, table below), the title, the `subtitle` under it (footnote secondary, one
  line), trailing the `value` formatted (secondary) and a chevron; a tap pushes the row's `page`.
- `note` — a footnote paragraph with an info glyph, secondary.
- `error` — a red exclamation glyph and "Couldn't read this panel" over the `message` (footnote secondary): one
  panel failed, the rest of the page stands.

**Chips** (`detail`): a chip is text (`{"t": "anthropic"}`) or a value (`{"v": 12345, "u": "tokens", "s": "in"}`:
formatted value, then a space and the suffix when there is one, "12.3K in"). A detail line joins its chips with
" · " and never breaks inside a value chip (its spaces are no-break spaces).

**Icons** (`links` rows and nothing else): `overview` square.grid.2x2 / `Dashboard`, `claude` sparkle /
`AutoAwesome`, `openrouter` arrow.triangle.branch / `AltRoute`, `crok` cpu / `Memory`, `harness` hammer / `Build`,
`history` calendar / `CalendarMonth`, `explorer` magnifyingglass / `Search`, `evaluators` checkmark.seal /
`Verified`, `guards` shield.lefthalf.filled / `Shield`, `experiments` flask / `Science`, `agents` person.2 /
`Groups`, `conversations` bubble.left.and.text.bubble.right / `Forum`, `slos` target / `TrackChanges`, `alerts`
bell / `NotificationsActive`; anything else chart.bar / `BarChart`.

**Numbers** (both apps the same; the locale's decimal separator, K / M / B in every language):

| unit | rule | examples |
|---|---|---|
| `usd` | 0 → "$0"; under 0.01 → 4 decimals, trailing zeros dropped; under 1,000 → 2 decimals; else compact with 1 decimal | $0.0042, $1.79, $1.2K |
| `count` | under 1,000: whole when whole, else 1 decimal; else compact (1 decimal under 100K, none above) | 7, 3.4, 1.2K, 340K, 1.2M |
| `tokens` | as `count` | 12.3M |
| `ratio` | × 100 with 1 decimal and "%", ".0" dropped; exactly 0 and 1 → "0%", "100%" | 2.9%, 96%, 99.4% |
| `seconds` | under 1 → "340 ms"; under 60 → 1 decimal "4.3 s"; under 3,600 → "2.1 min"; else "1.5 h" | |
| `ms` | divided by 1,000, then `seconds` | |
| `bytes` | 1,024 steps: "B", "KB", "MB", "GB", 1 decimal | 4.2 KB |
| `perMin` | `count` + "/min" | 12.3/min |
| `tps` | `count` + " tok/s" | 45 tok/s |

A `change` is a fraction: "+" or "−" (U+2212), × 100, no decimals ("+12%", "−8%"; under 1 % in size: "+0.4%");
null or a value the previous period divided by zero gives no change text.

**Demo mode** serves pages from the bundled fixture `o11y-demo.json` (iOS `Crok/Resources/`, Android
`app/src/debug/assets/`; both copies made by `relay/scripts/o11y-demo.mjs`): synthetic numbers built from the relay's own
page specs, English text plus a `strings` table per language that the demo applies to every title, label and chip.
`o11y:refresh` there only moves `builtAt` to now.

## Words (en, zh-Hans, ja, es, fr, de)

New strings; both apps use exactly these. Existing strings keep their translations ("Sessions", "Computers",
"Devices", "Link a computer", "Appearance", "Language", "Version", "Done", "Reorder", "New Session", "Sort by Recent
Activity", "Search sessions", "Archived", "Archive", "Unarchive", "Pin", "Online", "last seen %@", "Sign Out"…).

| en | zh-Hans | ja | es | fr | de |
|---|---|---|---|---|---|
| Profile | 个人资料 | プロフィール | Perfil | Profil | Profil |
| Mark All as Read | 全部标为已读 | すべて既読にする | Marcar todo como leído | Tout marquer comme lu | Alle als gelesen markieren |
| Mark as Read | 标为已读 | 既読にする | Marcar como leído | Marquer comme lu | Als gelesen markieren |
| Read (swipe) | 已读 | 既読 | Leído | Lu | Gelesen |
| Read All | 全部已读 | すべて既読 | Leer todo | Tout lire | Alle lesen |
| Edit | 编辑 | 編集 | Editar | Modifier | Bearbeiten |
| Archived Sessions | 已归档的会话 | アーカイブ済みのセッション | Sesiones archivadas | Sessions archivées | Archivierte Sitzungen |
| No computers yet | 还没有电脑 | まだコンピュータがありません | Aún no hay ordenadores | Aucun ordinateur pour l'instant | Noch keine Computer |
| No sessions on %@ yet | %@ 上还没有会话 | %@ にはまだセッションがありません | Aún no hay sesiones en %@ | Aucune session sur %@ pour l'instant | Noch keine Sitzungen auf %@ |
| %lld sessions · %@ | %lld 个会话 · %@ | %lld 件のセッション · %@ | %lld sesiones · %@ | %lld sessions · %@ | %lld Sitzungen · %@ |
| Session Theme | 会话主题 | セッションのテーマ | Tema de la sesión | Thème des sessions | Sitzungsdesign |
| Choose a Photo | 选择照片 | 写真を選択 | Elegir una foto | Choisir une photo | Foto auswählen |
| Blur | 模糊 | ぼかし | Desenfocar | Flou | Weichzeichnen |
| Color Mode | 颜色模式 | カラーモード | Modo de color | Mode de couleur | Farbmodus |
| No Theme | 无主题 | テーマなし | Sin tema | Aucun thème | Kein Design |
| Classic | 经典 | クラシック | Clásico | Classique | Klassisch |
| Home | 家 | ホーム | Hogar | Maison | Zuhause |
| Duckling | 小鸭 | ひよこ | Patito | Caneton | Küken |
| Snowman | 雪人 | 雪だるま | Muñeco de nieve | Bonhomme de neige | Schneemann |
| Diamond | 钻石 | ダイヤモンド | Diamante | Diamant | Diamant |
| Teacher | 老师 | 先生 | Profesor | Professeur | Lehrer |
| Tulip | 郁金香 | チューリップ | Tulipán | Tulipe | Tulpe |
| Purple Heart | 紫心 | 紫のハート | Corazón morado | Cœur violet | Lila Herz |
| Christmas Tree | 圣诞树 | クリスマスツリー | Árbol de Navidad | Sapin de Noël | Weihnachtsbaum |
| Video Game | 电子游戏 | ビデオゲーム | Videojuego | Jeu vidéo | Videospiel |
| Photo | 照片 | 写真 | Foto | Photo | Foto |
| All 214 tests pass. Want me to open a PR? | 214 项测试全部通过。要我开一个 PR 吗？ | 214 件のテストがすべて通りました。PR を作成しますか？ | Pasan las 214 pruebas. ¿Abro un PR? | Les 214 tests passent. J'ouvre une PR ? | Alle 214 Tests bestehen. Soll ich einen PR öffnen? |
| Yes, please. | 好的，请开吧。 | はい、お願いします。 | Sí, por favor. | Oui, merci. | Ja, bitte. |
| Contact the developer on GitHub | 在 GitHub 上联系开发者 | GitHub で開発者に連絡 | Contactar al desarrollador en GitHub | Contacter le développeur sur GitHub | Entwickler auf GitHub kontaktieren |
| Contact the developer on X | 在 X 上联系开发者 | X で開発者に連絡 | Contactar al desarrollador en X | Contacter le développeur sur X | Entwickler auf X kontaktieren |
| %lld unread (switcher line) | %lld 条未读 | 未読 %lld 件 | %lld sin leer | %lld non lus | %lld ungelesen |
| Default | 默认 | デフォルト | Predeterminado | Par défaut | Standard |
| Choose a Model | 选择模型 | モデルを選択 | Elegir un modelo | Choisir un modèle | Modell auswählen |
| Search models or providers | 搜索模型或提供商 | モデルやプロバイダを検索 | Buscar modelos o proveedores | Rechercher des modèles ou des fournisseurs | Modelle oder Anbieter suchen |
| Model changes apply to your next message. | 模型更改将从你的下一条消息开始生效。 | モデルの変更は次のメッセージから適用されます。 | El cambio de modelo se aplica a partir de tu próximo mensaje. | Le changement de modèle s'applique à votre prochain message. | Die Modelländerung gilt ab deiner nächsten Nachricht. |
| %@'s own choice | %@ 自己的设置 | %@ の設定どおり | Lo que use %@ | Le choix de %@ | Die Einstellung von %@ |
| Thinking level | 思考级别 | 思考レベル | Nivel de razonamiento | Niveau de réflexion | Denkstufe |
| Couldn't change the model | 无法更改模型 | モデルを変更できませんでした | No se pudo cambiar el modelo | Impossible de changer le modèle | Das Modell konnte nicht geändert werden |
| Couldn't change the thinking level | 无法更改思考级别 | 思考レベルを変更できませんでした | No se pudo cambiar el nivel de razonamiento | Impossible de changer le niveau de réflexion | Die Denkstufe konnte nicht geändert werden |
| No Results | 无结果 | 結果なし | Sin resultados | Aucun résultat | Keine Ergebnisse |
| Choose a session (web) | 选择一个会话 | セッションを選択 | Elige una sesión | Choisissez une session | Wähle eine Sitzung |
| o11y (tab; every language) | o11y | o11y | o11y | o11y | o11y |
| Updated %@ ("2 min ago") | 更新于%@ | %@に更新 | Actualizado %@ | Mis à jour %@ | Aktualisiert %@ |
| Open in Grafana | 在 Grafana 中打开 | Grafana で開く | Abrir en Grafana | Ouvrir dans Grafana | In Grafana öffnen |
| Loading o11y… | 正在加载 o11y… | o11y を読み込み中… | Cargando o11y… | Chargement d'o11y… | o11y wird geladen … |
| Couldn't update | 无法更新 | 更新できませんでした | No se pudo actualizar | Mise à jour impossible | Aktualisierung fehlgeschlagen |
| o11y is not available | o11y 不可用 | o11y は利用できません | o11y no está disponible | o11y n'est pas disponible | o11y ist nicht verfügbar |
| This account can't see the relay's Grafana stack. Ask whoever runs the relay to add it. | 此账号无法查看中继的 Grafana 栈。请让管理中继的人把它加进去。 | このアカウントではリレーの Grafana スタックを表示できません。リレーの管理者に追加を依頼してください。 | Esta cuenta no puede ver el stack de Grafana del relay. Pide a quien gestiona el relay que la añada. | Ce compte ne peut pas voir la pile Grafana du relais. Demandez à la personne qui gère le relais de l'ajouter. | Dieses Konto kann den Grafana-Stack des Relays nicht sehen. Bitte die Person, die das Relay betreibt, es hinzuzufügen. |
| o11y is not set up | o11y 尚未设置 | o11y は未設定です | o11y no está configurado | o11y n'est pas configuré | o11y ist nicht eingerichtet |
| The relay has no Grafana token yet. Run relay/scripts/o11y-setup.sh on the relay owner's computer. | 中继还没有 Grafana 令牌。请在中继所有者的电脑上运行 relay/scripts/o11y-setup.sh。 | リレーにはまだ Grafana トークンがありません。リレーの所有者のコンピュータで relay/scripts/o11y-setup.sh を実行してください。 | El relay aún no tiene un token de Grafana. Ejecuta relay/scripts/o11y-setup.sh en el ordenador de quien gestiona el relay. | Le relais n'a pas encore de jeton Grafana. Exécutez relay/scripts/o11y-setup.sh sur l'ordinateur du propriétaire du relais. | Das Relay hat noch kein Grafana-Token. Führe relay/scripts/o11y-setup.sh auf dem Computer der Person aus, der das Relay gehört. |
| This relay doesn't serve o11y yet. | 此中继尚未提供 o11y。 | このリレーはまだ o11y に対応していません。 | Este relay aún no ofrece o11y. | Ce relais ne propose pas encore o11y. | Dieses Relay bietet o11y noch nicht an. |
| %lldh (range; the session rows' existing string) | %lld小时 | %lld時間 | %lld h | %lld h | %lld Std |
| %lldd (range; the session rows' existing string) | %lld天 | %lld日 | %lld d | %lld j | %lld T |
| Range (the range control's label) | 时间范围 | 期間 | Periodo | Période | Zeitraum |
| %@, up %@ / %@, down %@ (a stat read aloud: "Spend, $2.75, up 12%") | %1$@，上升 %2$@ / %1$@，下降 %2$@ | %1$@、%2$@ 増加 / %1$@、%2$@ 減少 | %1$@, sube %2$@ / %1$@, baja %2$@ | %1$@, en hausse de %2$@ / %1$@, en baisse de %2$@ | %1$@, gestiegen um %2$@ / %1$@, gesunken um %2$@ |
| Warning (a list row's status, read aloud) | 警告 | 警告 | Advertencia | Avertissement | Warnung |
| No data in this range | 此时间范围内没有数据 | この期間のデータはありません | No hay datos en este periodo | Aucune donnée sur cette période | Keine Daten in diesem Zeitraum |
| and %lld more | 还有 %lld 项 | ほか %lld 件 | y %lld más | et %lld de plus | und %lld weitere |
| Couldn't read this panel | 无法读取此面板 | このパネルを読み込めませんでした | No se pudo leer este panel | Impossible de lire ce panneau | Dieses Panel konnte nicht gelesen werden |

The relay translates the pages' own words (titles, labels, chips, notes) into the six languages itself
(`relay/convex/lib/o11y/i18n.ts`); the phones translate only the words above.
