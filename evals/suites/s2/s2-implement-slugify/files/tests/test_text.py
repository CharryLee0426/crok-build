import unittest

from text import slugify


class SlugifyTest(unittest.TestCase):
    def test_punctuation(self):
        self.assertEqual(slugify("Hello, World!"), "hello-world")

    def test_spaces_and_dots(self):
        self.assertEqual(slugify("  Crok  2.1 release "), "crok-2-1-release")

    def test_empty(self):
        self.assertEqual(slugify("!!!"), "")
