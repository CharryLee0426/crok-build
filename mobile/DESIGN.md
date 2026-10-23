# Phone apps: computers as accounts, projects as groups, sessions as topics

Status: 2026-10-22. This is the contract both phone apps (`mobile/iOS`, `mobile/Android`) implement, so they look and
work the same. It replaces the phone part of relay/DESIGN.md §5 "The session list" (tabs All / per computer /
Archived, one section per project), which the web app keeps. Everything else in relay/DESIGN.md §5 (the session
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

## Dev builds

Debug builds (`mobile/scripts/build-apps.sh test`, the dev relay) carry a **yellow** icon, release builds (prod)
the blue one: the same mark on a yellow tile (`#FFD84D` → `#F6B800` top to bottom on iOS, flat `#F6B800` on
Android) with the mark in dark brown `#3D2E00`; the iOS dark variant keeps the dark tile with the mark in `#FFC933`.

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
