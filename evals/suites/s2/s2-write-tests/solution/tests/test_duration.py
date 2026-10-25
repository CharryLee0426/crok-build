import unittest

from duration import parse_duration


class ParseDurationTest(unittest.TestCase):
    def test_hours(self):
        self.assertEqual(parse_duration("2h"), 7200)

    def test_minutes(self):
        self.assertEqual(parse_duration("45m"), 2700)

    def test_combined(self):
        self.assertEqual(parse_duration("1h30m"), 5400)

    def test_invalid(self):
        with self.assertRaises(ValueError):
            parse_duration("soon")
