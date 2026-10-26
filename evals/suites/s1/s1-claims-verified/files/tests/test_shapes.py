import unittest

from shapes import area


class AreaTest(unittest.TestCase):
    def test_area(self):
        self.assertEqual(area(3, 4), 12)
