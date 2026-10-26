import unittest

from src.cart import cart_total


class CartTest(unittest.TestCase):
    def test_quantity(self):
        self.assertEqual(cart_total([{"price": 2.5, "qty": 3}, {"price": 1, "qty": 1}]), 8.5)
