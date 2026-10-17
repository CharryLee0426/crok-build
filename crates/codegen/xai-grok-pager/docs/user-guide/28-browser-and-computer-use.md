# Browser and Computer Use

Two optional tools let Crok work outside the terminal:

- **`browser`** drives a web browser of Crok's own: it opens pages, reads them, clicks, types, fills in forms, and manages tabs.
- **`computer`** sees your screen and uses the mouse and keyboard, in any app (macOS only).

Both are off until you turn them on. They are Crok's own tools, so they work with every model provider you can sign in to (OpenRouter, OpenAI Codex, the Claude API, DeepSeek, and the GLM Coding Plan), not only with Anthropic's API. Their actions follow Anthropic's browser and computer toolsets (`browser_toolset_20260801` and `computer_toolset_20260801`), so a model that knows those finds the same names, inputs, and replies.

---

## Turning Them On

| Where | How |
|---|---|
| Terminal | `/browser-use` and `/computer-use` (`on`, `off`, or nothing to switch), or `/settings` → **Browser use** / **Computer use** |
| Crok Desktop | **Settings** → **Browser and computer use**, or the same two commands |
| `config.toml` | `browser_use` and `computer_use` under `[features]` |
| Environment | `CROK_BROWSER_USE=1`, `CROK_COMPUTER_USE=1` |

```toml
[features]
browser_use = true
computer_use = true     # macOS only
```

The switches are read when a session starts. In the terminal, restart Crok after changing one; in Crok Desktop, every new task gets the change.

---

## The Browser

Crok runs the first Chromium-based browser it finds (Google Chrome, Chromium, Microsoft Edge, or Brave), or the one named by `[toolset.browser] executable`. It uses a profile of its own, `$CROK_HOME/browser/profile`, never your everyday browsing profile: sites Crok should be signed in to, you sign in to once in that window. The browser starts on the first browser action, or Crok connects to the one already running with that profile. Every session works in tabs of its own, and closes them when it ends.

What the model can do:

| Kind | Actions |
|---|---|
| Look | `screenshot`, `zoom`, `read_page` (the page's elements, each with a reference like `ref_12`), `find`, `get_page_text` |
| Act | `navigate` (an address, `back`, `forward`, or `reload`), `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click`, `hover`, `left_click_drag`, `left_mouse_down`, `left_mouse_up`, `mouse_move`, `scroll`, `scroll_to`, `type`, `key`, `hold_key`, `form_input`, `file_upload`, `wait` |
| Tabs | `new_tab`, `list_tabs`, `switch_tab`, `close_tab` |
| Debug | `read_console`, `read_network`, `javascript_exec` |

Clicks and other pointer actions take either an element reference from `read_page` or `find`, or a point in the last screenshot. Each reply ends with the session's tabs and which one is active. Several browser calls in one model response run in order; once one fails, the rest of that response's calls are not run, so the model looks again before going on.

Pages cannot stop the work with a dialog: alerts are accepted, confirmations and prompts are dismissed, and the reply says which dialogs appeared. Downloads are reported too.

---

## The Computer (macOS)

The `computer` tool takes screenshots of the main display and moves the pointer, clicks, scrolls, and types with the real mouse and keyboard. macOS asks for two permissions, for the app Crok runs in (your terminal app, or Crok Desktop):

- **Screen Recording**, to take screenshots.
- **Accessibility**, to move the pointer, click, and type.

Grant them in **System Settings → Privacy & Security**. Crok Desktop shows both in **Settings → Browser and computer use**, with a button that asks macOS for whichever is missing.

Every Crok Desktop version is signed with the same certificate, so these permissions carry over when it updates. In a terminal they belong to the terminal app, which a Crok update does not touch.

A few things keep it predictable:

- Screenshots are scaled to fit 1568 pixels on the long edge (about 1.15 megapixels). The model points in screenshot pixels, and Crok maps them back to the screen.
- One session at a time controls the mouse and keyboard. Another session that tries is told the computer is in use, until the first has been idle for two minutes or has quit.
- Only the main agent gets the `computer` tool; subagents do not.
- Keys and mouse buttons the model holds down are released when the action ends or fails. `hold_key` and `wait` last 60 seconds at most, and one `scroll` moves 30 steps at most.

To stop Crok mid-action, stop the turn: `Ctrl+C` in the terminal, or the stop button in Crok Desktop.

---

## Permissions

Both tools go through the same approvals as every other tool (see [Permissions and Safety](22-permissions-and-safety.md)):

- **Looking runs without asking**: screenshots, reading a page, finding text, opening and switching tabs, scrolling in the browser, moving the pointer, and reading the console or network requests are treated like reading a file.
- **Opening an address is a web fetch**: `navigate` is asked about per site, and `WebFetch(domain:…)` rules and remembered domains apply to it. Going back, forward, or reloading does not ask.
- **Acting asks first**: clicking, typing, and the other actions that change a page or the screen. Answer **Yes, allow browser actions for this session** (or **Yes, allow computer use for this session**) to stop being asked until the session ends.
- **Scripts and uploads ask every time**: `javascript_exec` runs code in the page, and `file_upload` sends files from the session's working directory (never from outside it). Turn either off with `[toolset.browser] javascript = false` or `file_upload = false`.

Always-approve and Auto-review apply as they do to other tools. To keep the browser on certain sites, set `allowed_domains` or `blocked_domains` under `[toolset.browser]`; `navigate` refuses the others.

---

## Choosing a Model

Any model that calls tools can use both. Screenshots need a model that reads images: computer use depends on them. With a text-only model, the browser still works through `read_page`, `find`, and `get_page_text`.

---

## Configuration

```toml
[toolset.browser]
# executable = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
headless = false                       # true = no window
# profile_dir = "/Users/me/crok-browser"   # absolute path (default: $CROK_HOME/browser/profile)
# allowed_domains = ["example.com"]    # hosts navigate may open, subdomains included (default: any)
blocked_domains = []                   # hosts navigate refuses, subdomains included
javascript = true                      # offer javascript_exec
file_upload = true                     # offer file_upload
```

Every key is listed in the [Configuration Reference](26-config-reference.md).

---

## Troubleshooting

| What you see | What to do |
|---|---|
| "No Chromium-based browser was found" | Install Chrome, Chromium, Edge, or Brave, or set `[toolset.browser] executable`. |
| The browser asks you to sign in again | Crok's browser has its own profile; sign in once in its window. |
| Computer screenshots fail or show only the desktop | Grant Screen Recording to the app Crok runs in, then quit and reopen that app. |
| Clicks and typing do nothing | Grant Accessibility to the app Crok runs in. |
| System Settings shows Crok Desktop switched on, but Crok says it is not allowed | The permission was given to a differently signed copy (an ad hoc signed version before the update). Remove Crok Desktop from that list with **−**, then allow it again. |
| "Computer use is in use by another Crok session" | Another session is using the computer; it frees up two minutes after that session's last action, or when it quits. |
| The tools are missing after turning them on | They are read when a session starts: restart Crok, or start a new task in Crok Desktop. |
