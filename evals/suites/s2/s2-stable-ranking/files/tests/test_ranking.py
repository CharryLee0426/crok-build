import unittest

from ranking import rank


class RankTest(unittest.TestCase):
    def test_order(self):
        names = [p["name"] for p in rank([{"name": "a", "score": 1}, {"name": "b", "score": 3}])]
        self.assertEqual(names, ["b", "a"])

    def test_ties_keep_order(self):
        players = [{"name": n, "score": s} for n, s in [("a", 2), ("b", 5), ("c", 2), ("d", 5)]]
        self.assertEqual([p["name"] for p in rank(players)], ["b", "d", "a", "c"])
