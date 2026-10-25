import json
import time

AUDIT_LOG = "audit.log"


def audit_summary():
    try:
        with open(AUDIT_LOG) as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def write_audit_entry(event):
    with open(AUDIT_LOG, "a") as f:
        f.write(json.dumps({"at": time.time(), **event}) + "\n")
