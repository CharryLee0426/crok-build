import unittest

from calc import double


class DoubleTest(unittest.TestCase):
    def test_double(self):
        self.assertEqual(double(4), 8)
