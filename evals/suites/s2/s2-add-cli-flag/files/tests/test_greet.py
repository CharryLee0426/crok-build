import unittest

from greet import main


class GreetTest(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(main(["--name", "Ada"]), "Hello, Ada!")

    def test_shout(self):
        self.assertEqual(main(["--name", "Ada", "--shout"]), "HELLO, ADA!")
