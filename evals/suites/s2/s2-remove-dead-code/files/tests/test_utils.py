import unittest

import app
import utils


class UtilsTest(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(app.handle("  Ada "), "ada")

    def test_helper_is_gone(self):
        self.assertFalse(hasattr(utils, "legacy_helper"))
