import os
import tempfile
import unittest

import storage
from model import Task


class PriorityTest(unittest.TestCase):
    def test_default(self):
        self.assertEqual(Task("a").priority, 0)

    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "t.json")
            storage.save([Task("a", priority=3)], path)
            self.assertEqual(storage.load(path)[0].priority, 3)

    def test_old_files_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "t.json")
            with open(path, "w") as f:
                f.write('[{"title": "old", "done": false}]')
            self.assertEqual(storage.load(path)[0].priority, 0)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            os.environ["TASKS_DB"] = os.path.join(tmp, "db.json")
            import importlib

            import cli
            importlib.reload(cli)
            self.assertEqual(cli.main(["add", "x", "--priority", "2"]).priority, 2)
