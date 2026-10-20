import asyncio
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app.core.net_safety import UnsafeURLError, validate_public_url, validate_url_syntax  # noqa: E402


class NetSafetyTest(unittest.TestCase):
    def _bad(self, url):
        with self.assertRaises(UnsafeURLError, msg=url):
            asyncio.run(validate_public_url(url))

    def test_blocks_private_and_metadata(self):
        for url in [
            "http://127.0.0.1/",
            "http://localhost:8000/memory",
            "http://169.254.169.254/latest/meta-data/",
            "http://10.0.0.5/",
            "http://192.168.1.10/",
            "http://172.16.0.1/",
            "http://100.64.0.1/",
            "http://[::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://0.0.0.0/",
            "http://metadata.google.internal/",
            "http://servico.internal/",
        ]:
            self._bad(url)

    def test_blocks_bad_scheme_creds_ports(self):
        for url in [
            "file:///etc/passwd",
            "ftp://example.com/",
            "http://user:pass@8.8.8.8/",
            "http://8.8.8.8:22/",
            "http:///nada",
            "not a url",
        ]:
            self._bad(url)

    def test_allows_public_literal_ip(self):
        self.assertEqual(validate_url_syntax("https://8.8.8.8/")[1], "8.8.8.8")
        self.assertEqual(asyncio.run(validate_public_url("https://1.1.1.1/x")), "https://1.1.1.1/x")


if __name__ == "__main__":
    unittest.main()
