import unittest

from mathutil import sum_range


class SumRangeTest(unittest.TestCase):
    def test_includes_both_ends(self):
        self.assertEqual(sum_range(1, 3), 6)

    def test_single_number(self):
        self.assertEqual(sum_range(5, 5), 5)
