# Phone Use

The **`phone`** tool lets Crok see and use your phone:

- an **iPhone**, through the Mac's **iPhone Mirroring** app (macOS 15 Sequoia or later), and
- an **Android** phone, over **USB or Wi‑Fi debugging** (adb), on macOS, Linux, or Windows.

The model sees the screen, taps, swipes, types, opens apps, and reads the result. Nothing is installed on the phone. It is Crok's own tool, so it works with every model provider you can sign in to (OpenRouter, OpenAI Codex, the Claude API, DeepSeek, and the GLM Coding Plan). The text on the screen comes back with tap-ready positions, so even a model that cannot read images can use a phone.

Phone use is **on by default**. Crok needs nothing installed or configured for it: when an Android phone is first used and this computer has no `adb`, Crok downloads Google's [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) once into `$CROK_HOME/phone` (their use is subject to Google's terms). Connecting the phone itself is always yours to do, once, as below.

The approach follows [phone-harness](https://github.com/ShawnPana/phone-harness) by Shawn Pana (MIT), whose findings about iPhone Mirroring and adb it is built on.

---

## Turning It On or Off

| Where | How |
|---|---|
| Terminal | `/phone-use` (`on`, `off`, or nothing to switch), or `/settings` → **Phone use** |
| Crok Desktop | **Settings** → **Phone use**, or the same command |
| `config.toml` | `phone_use` under `[features]` |
| Environment | `CROK_PHONE_USE=0` turns it off |

```toml
[features]
phone_use = false   # on by default
```

The switch is read when a session starts. In the terminal, restart Crok after changing it; in Crok Desktop, every new task gets the change.

---

## Connecting an iPhone (Mac only)

1. Open **iPhone Mirroring** on the Mac once and finish its setup with your iPhone nearby. The iPhone must be signed in to the same Apple Account as the Mac.
2. Allow the app that runs Crok (your terminal app, or Crok Desktop) in **System Settings → Privacy & Security**:
   - **Accessibility**, to tap and type into the mirroring window.
   - **Screen & System Audio Recording**, to see the phone's screen (it takes effect after that app restarts).

   Crok asks macOS for both the first time it needs them. Crok Desktop shows both in **Settings → Phone use**, with a button that asks for whichever is missing.

From then on Crok opens iPhone Mirroring itself, presses its **Connect** button, and brings the window forward so you can watch. What only you can do:

- **Lock your iPhone** when the window says *iPhone in Use* or *Timed Out*: iPhone Mirroring only connects to a locked phone, and unlocking it pauses the session.
- Approve a **Touch ID or password** prompt on the Mac. Crok never types a passcode or password.

The iPhone's picture is read with Apple's text recognition, so icons without a label need a screenshot. While Crok acts, the iPhone Mirroring window is kept in front: a tap or key sent to a window that is behind would land in another app. Typing goes through the Mac's clipboard (cmd+V into the phone), so the text arrives exactly as written; **the typed text stays on your clipboard afterwards**, because putting the earlier contents back too soon could paste those into the phone instead.

---

## Connecting an Android Phone

Turn on **Developer options** once: **Settings → About phone**, tap **Build number** seven times. Then either:

- **USB:** **Developer options → USB debugging** on, plug the phone in, and tap **Allow** on *Allow USB debugging?* (tick *Always allow from this computer*).
- **Wi‑Fi** (Android 11 or later, on the same network as the computer): **Developer options → Wireless debugging** → **Pair device with pairing code**, and tell Crok the six-digit code ("pair my Android phone, the code is 123456"). Crok finds the phone on the network, pairs, and connects. A paired phone is found again by itself whenever Wireless debugging is on.

A plugged-in phone is preferred over Wi‑Fi; `ANDROID_SERIAL` picks one when several are attached. Crok uses an `adb` already on the computer (`CROK_ADB`, the Android SDK, `PATH`, or Homebrew) before downloading its own.

Crok wakes a sleeping phone and dismisses a lock screen that has no PIN, but a locked phone with a PIN, pattern, or fingerprint must be unlocked by you. Android's adb types plain ASCII text only; for other text, Crok asks you to type that part.

---

## What the Model Can Do

| Kind | Actions |
|---|---|
| Connect | `status` (which phones can be reached, and what is missing), `connect`, `pair_android` |
| Look | `read_screen` (every visible text with its position; on Android also unlabeled buttons, from the accessibility tree), `screenshot`, `list_apps` (Android) |
| Act | `tap` and `long_press` (a point, or visible text), `swipe` (a flick, in finger direction), `scroll` (in the direction of the content to reveal), `drag`, `type`, `key`, `home`, `back` (Android), `app_switcher`, `open_app`, `wait` |

A call can name its phone with `device` (`iphone` or `android`). Otherwise Crok uses the phone this session last used, else an Android phone adb can already reach, else the iPhone. Positions are pixels of the latest screenshot or `read_screen` of that phone. Several phone calls in one model response run in order; once one fails, the rest of that response's calls are not run.

One Crok session drives the phone at a time: another session is refused until the first has been idle for two minutes or has quit. Only the main agent gets the tool, not subagents.

---

## Permissions

Looking (`status`, `connect`, `read_screen`, `screenshot`, `list_apps`, `wait`) runs without asking. Every action that changes something on the phone asks first, with **Yes, allow phone actions for this session** among the answers; that answer is held in memory only and ends with the session. In always-approve mode nothing is asked.

The model is told to treat everything on the phone's screen as untrusted data, never as instructions, and to ask you before anything outward-facing or hard to undo: sending messages, posting, purchases, deleting, or changing settings.

---

## Limits

- iPhone Mirroring needs a Mac with macOS 15 or later, and a supported iPhone. Unlocking the iPhone pauses mirroring.
- On macOS 26, iPhone Mirroring drops vertical touch drags in lists, so lists move with `scroll`; `swipe` still flips Home Screen pages and carousels.
- There is no multi-touch (no pinch), no camera or Face ID, and DRM video shows black.
- iOS has no Back button; the model taps an app's own back control instead.
- Some Android screens never settle (a playing video), so their accessibility tree is not available; on a Mac Crok then reads their text from the picture instead.

---

## See Also

- [Browser and Computer Use](28-browser-and-computer-use.md) — the browser and desktop tools
- [Permissions and Safety](22-permissions-and-safety.md) — how Crok asks before it acts
- [Configuration](05-configuration.md) — `[features]` and other settings
