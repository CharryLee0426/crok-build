import json

from model import Task


def save(tasks, path):
    with open(path, "w") as f:
        json.dump([{"title": t.title, "done": t.done} for t in tasks], f)


def load(path):
    with open(path) as f:
        return [Task(title=d["title"], done=d["done"]) for d in json.load(f)]
