import argparse
import os

import storage
from model import Task

DB = os.environ.get("TASKS_DB", "tasks.json")


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    add = sub.add_parser("add")
    add.add_argument("title")
    args = parser.parse_args(argv)
    tasks = storage.load(DB) if os.path.exists(DB) else []
    tasks.append(Task(title=args.title))
    storage.save(tasks, DB)
    return tasks[-1]


if __name__ == "__main__":
    main()
