import inspect
import unittest

import client
import settings
import worker


class TimeoutTest(unittest.TestCase):
    def test_setting(self):
        self.assertEqual(settings.DEFAULT_TIMEOUT, 60)

    def test_client_default(self):
        self.assertEqual(inspect.signature(client.fetch).parameters["timeout"].default, 60)

    def test_worker_default(self):
        self.assertEqual(worker.Worker().timeout, 60)

    def test_one_source(self):
        settings.DEFAULT_TIMEOUT = 75
        try:
            self.assertEqual(worker.Worker().timeout, 75)
        finally:
            settings.DEFAULT_TIMEOUT = 60
