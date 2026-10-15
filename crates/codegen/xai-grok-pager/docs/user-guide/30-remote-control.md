# Remote Control

Remote control lets you follow and steer the sessions running on this computer from the **Crok app** on your phone
(iOS and Android) or from the **web**:

- see every session on every signed-in computer, with its status (working, waiting for approval, idle, offline);
- read the transcript as it streams: your prompts, the replies, tool calls, the plan;
- send a prompt into a session, as if typed here;
- stop the running turn;
- see the session's info: model, thinking level, folder, branch, tokens, cost and context.

It goes through a **relay** you run yourself: a Convex deployment with a small web app on Vercel (sign-in with GitHub or
Google through Clerk). Setting one up is described in [`relay/README.md`](../../../../../relay/README.md) in the
repository; how it works, in [`relay/DESIGN.md`](../../../../../relay/DESIGN.md).

Signing in here is **optional** and **separate from model-provider sign-in**: it links this computer to your
remote-control account and has nothing to do with model keys. Until you sign in, nothing leaves this computer.

---

## Signing In

| Where | How |
|---|---|
| Terminal | `crok remote login --server https://<deployment>.convex.cloud` |
| TUI | `/remote login https://<deployment>.convex.cloud` |
| Crok Desktop | **Settings** → **Remote control** → **Sign in…** |

You get a short code (`BCDF-GHJK`), a link and, in the terminal, a QR code. Open the link (Crok opens it for you when it
can), sign in with GitHub or Google, check that the page names this computer, and approve it. A phone already signed in
to the Crok app can approve it too: **Settings** → **Link a computer**, then scan the QR code.

Only approve a sign-in you just started yourself. The code works for ten minutes.

The relay address is saved as `[remote] url` in `config.toml`, so later sign-ins need no `--server`. The link itself is
kept in `$CROK_HOME/remote/credentials.json`, readable only by you.

## What Is Shared

While this computer is signed in, every running crok process mirrors its sessions to the relay: the TUI, and each task in
Crok Desktop. A session appears on your phone once it has a prompt (or right away, when you resume one with history), with
its last few turns.

Phones and the web can then send prompts into it. A prompt from a phone runs here exactly like one you type: the TUI shows
it with a **Prompt from <phone>** notice, Crok Desktop with a small **from <phone>** caption. If a turn is already running,
the phone's prompt waits and runs when it ends. Permission prompts still appear here, on this computer; the phone shows
**Waiting for approval on <computer>**.

The footer shows **● remote** while the link is up (**○ remote** while it connects).

## Turning It Off

| | |
|---|---|
| Stop sharing, stay signed in | `/remote off`, the **Share tasks with my phone** switch in Crok Desktop, or `[remote] enabled = false` |
| Sign this computer out | `crok remote logout`, `/remote logout`, or **Sign out** in Crok Desktop |
| Sign it out from elsewhere | **Devices** in the Crok app or on the web |

```toml
[remote]
enabled = true                                  # mirror sessions while signed in (default)
url = "https://<deployment>.convex.cloud"       # the relay
```

`CROK_REMOTE_CONTROL=0` turns it off for one run; `CROK_REMOTE_URL` overrides the relay.

## Checking

```sh
crok remote status          # signed in? as whom, which relay, is the link still valid
crok remote status --json
```

`/remote` in the TUI shows the same, plus whether the link is up right now.

## Limits

- Sessions run through the leader (`[cli] use_leader = true`), `crok agent serve` and headless `crok -p` are not mirrored.
- The relay keeps the text of each item up to 32 000 characters (this computer keeps all of it) and drops its copy of a
  session 30 days after the session was last active.
- Answering permission prompts from the phone, push notifications, and starting new sessions from the phone are not
  there yet.
