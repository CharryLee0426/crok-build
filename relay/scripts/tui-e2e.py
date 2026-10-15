#!/usr/bin/env python3
"""Drives the real crok TUI in a pseudo-terminal while a pretend phone (relay/scripts/phone-sim.mjs) uses the relay.

Checks: /remote login in the TUI (approved via `npx convex run --identity`), a typed prompt is mirrored, the footer
shows the link, a phone prompt runs in the TUI (echo + toast), /remote shows the status, quitting takes the session
offline.

    python3 scripts/mock-llm.py 18765 &          # a model for the agent (CROK_HOME/config.toml points at it)
    python3 scripts/tui-e2e.py <crok binary> <CROK_HOME> <project dir> <path to relay/>

CROK_HOME must not be signed in yet. The screen is read from the raw terminal stream, so a line the TUI redraws
partially may only match in part.
"""
import json
import os
import pty
import re
import select
import subprocess
import sys
import time

CROK = sys.argv[1]
HOME = sys.argv[2]
PROJECT = sys.argv[3]
RELAY_DIR = sys.argv[4]
ISSUER = subprocess.run(["npx", "convex", "env", "get", "CLERK_JWT_ISSUER_DOMAIN"], cwd=RELAY_DIR,
                        capture_output=True, text=True).stdout.strip()
PERSON = json.dumps({"subject": f"tui-e2e-{int(time.time())}", "issuer": ISSUER, "name": "TUI Tester",
                     "email": "tui@example.com"})
env = dict(os.environ, CROK_HOME=HOME, CROK_DISABLE_AUTOUPDATER="1", TERM="xterm-256color", COLUMNS="160", LINES="48")
phone_env = dict(os.environ, PHONE_SIM_APPROVE_AS=PERSON, PHONE_SIM_STATE="/tmp/crok-tui-e2e-phone.json")

failures = 0
def check(ok, label, detail=None):
    global failures
    if ok:
        print(f"  ok  {label}")
    else:
        failures += 1
        print(f"  FAIL {label}" + (f": {str(detail)[:600]}" if detail is not None else ""))

pid, fd = pty.fork()
if pid == 0:
    os.chdir(PROJECT)
    os.execve(CROK, [CROK], env)

import fcntl, struct, termios
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
            # Respond to cursor-position queries so the TUI does not wait on them.
            if "\x1b[6n" in text:
                os.write(fd, b"\x1b[1;1R")
            screen += ANSI.sub("", text)

def wait_for(pattern, seconds, label):
    end = time.time() + seconds
    while time.time() < end:
        pump(0.3)
        if re.search(pattern, screen):
            return True
    check(False, label, screen[-1500:])
    return False

def type_text(text):
    for ch in text:
        os.write(fd, ch.encode())
        time.sleep(0.01)
    time.sleep(0.2)
    os.write(fd, b"\r")

def phone(*args, timeout=120):
    out = subprocess.run(["node", "scripts/phone-sim.mjs", *args], cwd=RELAY_DIR, env=phone_env,
                         capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(out.stderr[-800:])
    return out.stdout

print("TUI starts")
pump(8)
# A first-run folder-trust question, if any, is answered yes.
if re.search(r"[Tt]rust", screen[-3000:]):
    os.write(fd, b"\r")
    pump(2)

print("/remote login in the TUI")
mark = len(screen)
type_text("/remote login http://127.0.0.1:3210")
if wait_for(r"[B-Z]{4}-[B-Z]{4}", 30, "the TUI shows a code"):
    code = re.findall(r"[B-Z]{4}-[B-Z]{4}", screen[mark:])[-1]
    subprocess.run(["npx", "convex", "run", "deviceAuth:approve", json.dumps({"userCode": code}), "--identity", PERSON],
                   cwd=RELAY_DIR, capture_output=True, text=True, check=True)
    check(wait_for(r"Signed in as TUI Tester", 30, "the TUI says it is signed in"), "signed in from the TUI")
check(os.path.exists(os.path.join(HOME, "remote", "credentials.json")), "credentials saved")

print("a typed prompt")
type_text("hello from the terminal ui")
wait_for(r"Hi from mock", 60, "the mock replies")
check(wait_for(r"● remote", 20, "footer shows the link"), "footer shows ● remote")

print("phone")
phone("link", "TUI Phone")
sessions = []
end = time.time() + 30
while time.time() < end:
    sessions = json.loads(phone("list"))
    if any(s["app"] == "tui" and s["online"] for s in sessions):
        break
    time.sleep(1)
tui_session = next((s for s in sessions if s["app"] == "tui" and s["online"]), None)
check(tui_session is not None, "the TUI's session is listed", sessions)
if tui_session:
    events = json.loads(phone("events", tui_session["_id"]))
    check(any(e["kind"] == "user" and e["text"] == "hello from the terminal ui" for e in events), "the typed prompt is mirrored",
          [(e["kind"], e["text"][:40]) for e in events])
    mark = len(screen)
    result = json.loads(phone("send", tui_session["_id"], "remote prompt into the tui"))
    check(result["status"] == "done", "the phone's prompt finishes", result)
    pump(3)
    after = screen[mark:]
    check("prompt into the" in after, "the TUI shows the phone's prompt", after[-1200:])
    check("Prompt from TUI Phone" in after, "the TUI shows a toast", after[-1200:])
    info = json.loads(phone("info", tui_session["_id"]))
    check(info.get("model") and info.get("cwd") == PROJECT, "session info from the TUI", info)

print("/remote")
mark = len(screen)
type_text("/remote")
check(wait_for(r"Remote control: connected", 15, "/remote shows the status"), "/remote shows connected")

print("quit")
type_text("/quit")
pump(5)
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
if tui_session:
    gone = False
    end = time.time() + 20
    while time.time() < end:
        sessions = json.loads(phone("list"))
        row = next((s for s in sessions if s["_id"] == tui_session["_id"]), None)
        if row and not row["online"]:
            gone = True
            break
        time.sleep(1)
    check(gone, "the session goes offline when the TUI quits")
phone("logout")
print("\nAll checks passed." if failures == 0 else f"\n{failures} check(s) failed.")
sys.exit(1 if failures else 0)
