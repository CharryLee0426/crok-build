import unittest

from billing.core import compute_total
from billing.report import report_line


class BillingTest(unittest.TestCase):
    def test_total(self):
        self.assertEqual(compute_total([{"price": 2, "qty": 3}, {"price": 1, "qty": 1}]), 7)

    def test_report(self):
        self.assertEqual(report_line("a", [{"price": 1.5, "qty": 2}]), "a: 3.00")
