#!/usr/bin/env python3
"""Drives the real crok TUI in a pseudo-terminal as one of two computers of the same person: the other one is
relay/scripts/fake-computer.mjs. The TUI lists the other computer's session in /resume, opens it, shows its
transcript, sends a prompt that runs over there, and shows the reply streaming back.

    python3 scripts/mock-llm.py 18765 &          # a model for the TUI's own agent (CROK_HOME/config.toml)
    python3 scripts/tui-remote-e2e.py <crok binary> <CROK_HOME> <project dir> <path to relay/>

CROK_HOME must not be signed in yet. The screen is read from the raw terminal stream.
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
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\x1b[=>]")


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


def wait_for(pattern, seconds, label, since=0):
    end = time.time() + seconds
    while time.time() < end:
        pump(0.3)
        if re.search(pattern, screen[since:]):
            return True
    check(False, label, screen[-1800:])
    return False


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
mark = len(screen)
type_text("/remote new")
check(wait_for(r"webapp\W*·\W*Test\W*MacBook", 30, "it lists the other computer's projects", mark),
      "/remote new lists the other computer's projects")
pump(1)
mark = len(screen)
type_text("/remote new 1 hello from a new desk session")
check(wait_for(r"hello\W*from\W*a\W*new\W*desk\W*session", 40, "the new session opens with its prompt", mark),
      "it starts one there and opens it")
check(wait_for(r"You\W*asked", 60, "the new session's reply streams back", mark), "and opens it with the reply streaming in")
check(any("session started" in line for line in fake_log), "the other computer opened it", fake_log[-8:])

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
