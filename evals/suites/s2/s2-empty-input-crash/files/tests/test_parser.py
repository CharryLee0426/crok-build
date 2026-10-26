import unittest

from parser import parse_pairs


class ParsePairsTest(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(parse_pairs("a=1,b=2"), {"a": "1", "b": "2"})

    def test_empty(self):
        self.assertEqual(parse_pairs(""), {})

    def test_trailing_comma(self):
        self.assertEqual(parse_pairs("a=1,"), {"a": "1"})

    def test_spaces(self):
        self.assertEqual(parse_pairs(" a = 1 , b= 2"), {"a": "1", "b": "2"})
