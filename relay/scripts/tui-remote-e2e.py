#!/usr/bin/env python3
"""Drives the real crok TUI in a pseudo-terminal as one of two computers of the same person: the other one is
relay/scripts/fake-computer.mjs. The TUI lists the other computer's session in /resume, opens it, shows its
transcript, sends a prompt that runs over there, and shows the reply streaming back. Then the Remote panel (`/remote`):
the other computer with its project and sessions, opening one from there, and a new session started from it with a
model and thinking level from that computer's list.

    python3 scripts/mock-llm.py 18765 &          # a model for the TUI's own agent (CROK_HOME/config.toml)
    python3 scripts/tui-remote-e2e.py <crok binary> <CROK_HOME> <project dir> <path to relay/>

CROK_HOME must not be signed in yet. The screen is read from the raw terminal stream, and kept as a 48x160 grid for the
panel's checks; E2E_SCREENS=<dir> writes the panel's screens there as text.
"""
import json
import os
import pty
import re
import select
import subprocess
import sys
import threading
import time
import unicodedata

CROK = sys.argv[1]
HOME = sys.argv[2]
PROJECT = sys.argv[3]
RELAY_DIR = sys.argv[4]
ISSUER = subprocess.run(["npx", "convex", "env", "get", "CLERK_JWT_ISSUER_DOMAIN"], cwd=RELAY_DIR,
                        capture_output=True, text=True).stdout.strip()
PERSON = json.dumps({"subject": f"tui-remote-e2e-{int(time.time())}", "issuer": ISSUER, "name": "Two Desk Tester",
                     "email": "two@example.com"})


def relay_url():
    if os.environ.get("CONVEX_URL"):
        return os.environ["CONVEX_URL"]
    with open(os.path.join(RELAY_DIR, ".env.local"), encoding="utf8") as f:
        for line in f:
            if line.startswith("NEXT_PUBLIC_CONVEX_URL="):
                return line.split("=", 1)[1].strip()
    return "http://127.0.0.1:3210"


RELAY = relay_url()
env = dict(os.environ, CROK_HOME=HOME, CROK_DISABLE_AUTOUPDATER="1", TERM="xterm-256color", COLUMNS="160", LINES="48",
           CROK_REMOTE_URL=RELAY)

failures = 0


def check(ok, label, detail=None):
    global failures
    if ok:
        print(f"  ok  {label}")
    else:
        failures += 1
        print(f"  FAIL {label}" + (f": {str(detail)[:900]}" if detail is not None else ""))


print("the other computer (fake)")
fake = subprocess.Popen(["node", "scripts/fake-computer.mjs"], cwd=RELAY_DIR,
                        env=dict(os.environ, FAKE_COMPUTER_AS=PERSON), stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True)
fake_log = []


def read_fake():
    for line in fake.stdout:
        fake_log.append(line.rstrip())


threading.Thread(target=read_fake, daemon=True).start()
end = time.time() + 60
while time.time() < end and not any("ready" in line for line in fake_log):
    time.sleep(0.3)
check(any("ready" in line for line in fake_log), "the other computer is up with a session", fake_log[-5:])

pid, fd = pty.fork()
if pid == 0:
    os.chdir(PROJECT)
    os.execve(CROK, [CROK], env)

import fcntl, struct, termios  # noqa: E402
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 48, 160, 0, 0))
screen = ""
# Kitty graphics commands (`ESC _ G … ESC \`) come too where the terminal is taken for one that shows images.
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b_[^\x1b]*\x1b\\|\x1b[()][A-Z0-9]|\x1b[=>]")
CSI = re.compile(r"\x1b\[([0-?]*)[ -/]*([@-~])")


class Term:
    """Just enough of a terminal to read the TUI's screen as rows of text: cursor moves, erases, scrolling and wide
    characters; colours and modes are dropped."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.pending = ""

    def clear(self, rows):
        for r in rows:
            self.grid[r] = [" "] * self.cols

    def scroll(self):
        self.grid.pop(0)
        self.grid.append([" "] * self.cols)

    def put(self, ch):
        if unicodedata.combining(ch):
            return
        wide = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if self.c + wide > self.cols:
            return
        self.grid[self.r][self.c] = ch
        if wide == 2:
            self.grid[self.r][self.c + 1] = ""
        self.c += wide

    def csi(self, params, final):
        private = params.startswith("?")
        nums = [int(p) if p.isdigit() else 0 for p in params.lstrip("?").split(";")] if params else []
        n = nums[0] if nums and nums[0] else 1
        if final in "Hf":
            row = nums[0] if len(nums) > 0 and nums[0] else 1
            col = nums[1] if len(nums) > 1 and nums[1] else 1
            self.r, self.c = min(row, self.rows) - 1, min(col, self.cols) - 1
        elif final == "G":
            self.c = min(n, self.cols) - 1
        elif final == "d":
            self.r = min(n, self.rows) - 1
        elif final == "A":
            self.r = max(0, self.r - n)
        elif final == "B":
            self.r = min(self.rows - 1, self.r + n)
        elif final == "C":
            self.c = min(self.cols - 1, self.c + n)
        elif final == "D":
            self.c = max(0, self.c - n)
        elif final == "J":
            mode = nums[0] if nums else 0
            if mode == 0:
                self.grid[self.r][self.c:] = [" "] * (self.cols - self.c)
                self.clear(range(self.r + 1, self.rows))
            elif mode == 1:
                self.clear(range(0, self.r))
            else:
                self.clear(range(self.rows))
        elif final == "K":
            mode = nums[0] if nums else 0
            if mode == 0:
                self.grid[self.r][self.c:] = [" "] * (self.cols - self.c)
            elif mode == 1:
                self.grid[self.r][: self.c + 1] = [" "] * (self.c + 1)
            else:
                self.clear([self.r])
        elif final == "X":
            end = min(self.cols, self.c + n)
            self.grid[self.r][self.c:end] = [" "] * (end - self.c)
        elif final == "S":
            for _ in range(n):
                self.scroll()
        elif final in "hl" and private and 1049 in nums:
            self.clear(range(self.rows))

    def feed(self, data):
        text = self.pending + data
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b":
                if i + 1 >= len(text):
                    break
                nxt = text[i + 1]
                if nxt == "[":
                    m = CSI.match(text, i)
                    if not m:
                        break
                    self.csi(m.group(1), m.group(2))
                    i = m.end()
                    continue
                if nxt in "]P_":
                    ends = [e for e in (text.find("\x07", i), text.find("\x1b\\", i + 2)) if e >= 0]
                    if not ends:
                        break
                    end = min(ends)
                    i = end + (1 if text[end] == "\x07" else 2)
                    continue
                i += 3 if nxt in "()" else 2
                continue
            if ch == "\r":
                self.c = 0
            elif ch == "\n":
                if self.r == self.rows - 1:
                    self.scroll()
                else:
                    self.r += 1
            elif ch == "\b":
                self.c = max(0, self.c - 1)
            elif ord(ch) >= 32:
                self.put(ch)
            i += 1
        self.pending = text[i:]

    def dump(self):
        return "\n".join("".join(row).rstrip() for row in self.grid)


term = Term(48, 160)


def pump(seconds):
    global screen
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            text = data.decode("utf-8", "replace")
            if "\x1b[6n" in text:
                os.write(fd, b"\x1b[1;1R")
            screen += ANSI.sub("", text)
            term.feed(text)


def wait_for(pattern, seconds, label, since=0):
    end = time.time() + seconds
    while time.time() < end:
        pump(0.3)
        if re.search(pattern, screen[since:]):
            return True
    check(False, label, screen[-1800:])
    return False


def wait_screen(pattern, seconds, label):
    """Waits until the screen as drawn now (not the stream) matches."""
    end = time.time() + seconds
    while time.time() < end:
        pump(0.3)
        if re.search(pattern, term.dump()):
            return True
    check(False, label, term.dump())
    return False


def panel_text():
    """The Remote panel's rectangle, from its title row to its key hints: what the checks read."""
    rows = term.dump().splitlines()
    top = next((i for i, row in enumerate(rows) if "Other computers" in row or "New session" in row), None)
    if top is None:
        return ""
    left = len(rows[top]) - len(rows[top].lstrip())
    right = len(rows[top])
    bottom = next((i for i in range(top + 1, len(rows)) if "Esc " in rows[i]), len(rows) - 1)
    return "\n".join(row[left:right] for row in rows[top:bottom + 1])


SCREENS = os.environ.get("E2E_SCREENS")


def keep_screen(name):
    if SCREENS:
        os.makedirs(SCREENS, exist_ok=True)
        with open(os.path.join(SCREENS, f"{name}.txt"), "w", encoding="utf8") as f:
            f.write(term.dump() + "\n")


def convex(function, args):
    """A relay function run as the test person; its JSON result."""
    out = subprocess.run(["npx", "convex", "run", function, json.dumps(args), "--identity", PERSON], cwd=RELAY_DIR,
                         capture_output=True, text=True)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def type_keys(text):
    for ch in text:
        os.write(fd, ch.encode())
        time.sleep(0.02)


def type_text(text):
    type_keys(text)
    time.sleep(0.2)
    os.write(fd, b"\r")


print("TUI starts and signs in")
pump(8)
if re.search(r"[Tt]rust", screen[-3000:]):
    os.write(fd, b"\r")
    pump(2)
mark = len(screen)
type_text("/remote login")
if wait_for(r"[B-Z]{4}-[B-Z]{4}", 30, "the TUI shows a code", mark):
    code = re.findall(r"[B-Z]{4}-[B-Z]{4}", screen[mark:])[-1]
    subprocess.run(["npx", "convex", "run", "deviceAuth:approve", json.dumps({"userCode": code}), "--identity", PERSON],
                   cwd=RELAY_DIR, capture_output=True, text=True, check=True)
    check(wait_for(r"Signed in as Two Desk Tester", 30, "the TUI says it is signed in", mark), "signed in from the TUI")
check(wait_for(r"● remote", 30, "footer shows the link"), "footer shows ● remote")

print("/resume lists the other computer's session")
pump(3)
mark = len(screen)
type_text("/resume")
listed = wait_for(r"Fix the login redirect", 30, "the picker lists the other computer's session", mark)
check(listed, "the picker lists the other computer's session")
check("Test MacBook" in screen[mark:] and "other computer" in screen[mark:], "named with its computer and badge",
      screen[mark:][-1500:])

print("open it")
type_keys("login redirect")
pump(3)
mark = len(screen)
os.write(fd, b"\r")
check(wait_for(r"provider\W*sends\W*it", 40, "the transcript opens in the TUI", mark), "its transcript opens in the TUI")

print("a prompt runs on the other computer")
pump(2)
mark = len(screen)
type_text("hello from the second desk")
# The TUI moves the cursor instead of writing spaces, so words may run together in the raw stream.
check(wait_for(r"You\W*asked", 60, "the reply streams back", mark), "the reply from the other computer streams in")
# Spinner frames and token counters are drawn in between, so allow a gap.
whole = wait_for(r"(?s)sign-up\W*flow.{0,40}Done\W*for.{0,120}now", 30, "the whole reply arrives", mark)
check(whole, "the whole reply arrives", None if whole else re.findall(r"asked.{0,500}", screen[mark:], re.S)[-3:])
check(any("claimed prompt" in line and "hello from the second desk" in line for line in fake_log),
      "the other computer ran it", fake_log[-8:])

print("the model and thinking level of the other computer's session")
pump(2)
type_text("/model grok-4")
end = time.time() + 30
while time.time() < end and not any("config model = grok-4" in line for line in fake_log):
    pump(0.3)
check(any("config model = grok-4" in line for line in fake_log), "/model switches the model over there", fake_log[-6:])
pump(2)
type_text("/model grok-4 low")
end = time.time() + 30
while time.time() < end and not any("config reasoning_effort = low" in line for line in fake_log):
    pump(0.3)
check(any("config reasoning_effort = low" in line for line in fake_log), "and its thinking level, from that computer's list",
      fake_log[-6:])
config_toml = open(os.path.join(HOME, "config.toml"), encoding="utf8").read()
check("grok-4" not in config_toml, "the other computer's model does not become this one's default")

print("/remote new starts a session on the other computer")
pump(2)
type_text("/remote new")
# With no argument it opens the Remote panel at the project list (tried below); Esc closes it.
check(wait_screen(r"Other computers(.|\n)*Test MacBook(.|\n)*webapp", 30, "/remote new opens the panel"),
      "/remote new shows the other computer's projects")
os.write(fd, b"\x1b")
pump(2)
check("Other computers" not in term.dump(), "Esc closes the panel", term.dump())
mark = len(screen)
type_text("/remote new 1 hello from a new desk session")
check(wait_for(r"hello\W*from\W*a\W*new\W*desk\W*session", 40, "the new session opens with its prompt", mark),
      "it starts one there and opens it")
check(wait_for(r"You\W*asked", 60, "the new session's reply streams back", mark), "and opens it with the reply streaming in")
check(any("session started" in line for line in fake_log), "the other computer opened it", fake_log[-8:])

print("the Remote panel lists the other computer, its project and sessions")
pump(2)
type_text("/remote")
if wait_screen(r"Other computers", 30, "/remote opens the panel"):
    wait_screen(r"Fix the login redirect", 20, "the panel lists the other computer's sessions")
    dump = panel_text()
    keep_screen("panel-tree")
    check(re.search(r"connected", dump) and "Two Desk Tester" in dump, "its header names the account and the link", dump)
    check(re.search(r"Test MacBook\s+● online", dump), "the other computer, online", dump)
    check(re.search(r"webapp\s+\S*webapp.*sessions", dump), "its project with the folder and the session count", dump)
    check("hello from a new desk session" in dump, "the session started with /remote new is there too", dump)

print("open a session from the panel")
type_keys("login redirect")
pump(2)
keep_screen("panel-filtered")
check("Fix the login redirect" in panel_text() and "hello from a new desk" not in panel_text(), "typing filters the tree",
      panel_text())
os.write(fd, b"\r")
# That session is open in another tab already (from /resume): the panel switches to it, at its newest turn.
opened = wait_screen(r"hello from the second desk", 40, "the session opens from the panel")
check(opened and "Other computers" not in term.dump(), "Enter on a session opens it here")
if opened:
    pump(3)
    keep_screen("session-from-panel")
    status = term.dump()
    check("fix/login-redirect" in status, "the status line shows that session's branch", status)
    check(re.search(r"↑\d+(\.\d)?[kKM] ↓\d+(\.\d)?[kKM]", status), "and its token figures", status)

print("a new session from the panel, with a model and thinking level from that computer")
pump(1)
type_text("/remote new")
if wait_screen(r"Other computers", 30, "/remote new opens the panel at the project list"):
    pump(1)
    keep_screen("panel-projects")
    os.write(fd, b"n")
    if wait_screen(r"Grok Code Fast", 30, "n asks for the model"):
        dump = panel_text()
        keep_screen("panel-models")
        check(re.search(r"Default(.|\n)*Grok Code Fast(.|\n)*Grok 4(.|\n)*Grok 3 Mini", dump),
              "Default first, then that computer's models", dump)
        check("The most capable model" in dump, "with their descriptions", dump)
        type_keys("grok 4")
        pump(1)
        keep_screen("panel-models-filtered")
        check("Grok Code Fast" not in panel_text() and "Grok 4" in panel_text(), "typing filters the models",
              panel_text())
        os.write(fd, b"\r")
        if wait_screen(r"Extra high", 20, "a model with levels asks for the thinking level"):
            keep_screen("panel-thinking")
            check(re.search(r"Default\s+Medium", panel_text()), "Default first, naming the model's own level",
                  panel_text())
            type_keys("extra")
            pump(1)
            mark = len(screen)
            os.write(fd, b"\r")
            started = wait_for(r"Started\W*a\W*session\W*in\W*webapp\W*on\W*Test\W*MacBook", 40,
                               "the new session opens", mark)
            check(started, "the panel starts the session there and opens it here")
            end = time.time() + 30
            while time.time() < end and not any("model grok-4 effort xhigh" in line for line in fake_log):
                pump(0.3)
            check(any("model grok-4 effort xhigh asked for grok-4 xhigh" in line for line in fake_log),
                  "the other computer started it with that model and thinking level", fake_log[-6:])
            # The first session was switched to Grok 4 by /model above; the new one is the other Grok 4 session.
            groups = convex("sessions:groups", {}) or []
            rows = [row for group in groups for row in group.get("sessions", []) if row.get("model") == "grok-4"
                    and row.get("title") != "Fix the login redirect"]
            details = [convex("sessions:get", {"sessionDocId": row["_id"]}) or {} for row in rows]
            check(any(d.get("effort") == "xhigh" and (d.get("cwd") or "").endswith("webapp") for d in details),
                  "the relay's session row has them", details or groups)
            pump(2)
            keep_screen("new-session")
            mark = len(screen)
            type_text("first prompt from the panel")
            check(wait_for(r"You\W*asked", 60, "the first prompt runs there", mark), "the person types its first prompt")
            check(any("claimed prompt" in line and "first prompt from the panel" in line for line in fake_log),
                  "and it runs on the other computer", fake_log[-8:])

print("a session started on this computer from the web")
pump(2)
devices = convex("devices:list", {}) or []
this_computer = next((d for d in devices if d.get("kind") == "computer" and d.get("name") != "Test MacBook"), None)
check(this_computer, "this computer is a linked device", devices)
if this_computer:
    mark = len(screen)
    created = convex("sessions:create", {"deviceId": this_computer["_id"], "path": PROJECT,
                                         "text": "started on the web for this desk", "clientId": str(time.time())})
    check(created and created.get("sessionDocId"), "the web starts a session on this computer", created)
    # This TUI's crok opens it out of sight; the TUI says so, and the Remote panel lists it under "This computer".
    check(wait_for(r"Web\W*started\W*a\W*session", 60, "the TUI announces it", mark),
          "the TUI announces the session the web started here")
    pump(2)
    type_text("/remote")
    if wait_screen(r"This computer", 30, "the panel lists this computer's session"):
        keep_screen("panel-this-computer")
        dump = panel_text()
        check("from Web" in dump and "started from other devices" in dump, "named with where it came from", dump)
    os.write(fd, b"\x1b")
    pump(1)

print("quit")
type_text("/quit")
pump(4)
try:
    os.kill(pid, 15)
except ProcessLookupError:
    pass
end = time.time() + 10
while time.time() < end:
    pump(0.2)
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
fake.terminate()
try:
    fake.wait(10)
except subprocess.TimeoutExpired:
    fake.kill()
subprocess.run([CROK, "remote", "logout", "--json"], env=env, capture_output=True, text=True)
print("\nAll checks passed." if failures == 0 else f"\n{failures} check(s) failed.")
sys.exit(1 if failures else 0)
