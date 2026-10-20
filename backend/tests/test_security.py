import os
import sys
import unittest
import types

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# stub mínimo do fastapi (só para importar o módulo em ambiente sem dependências)
try:
    import fastapi  # noqa: F401
except ModuleNotFoundError:
    fa = types.ModuleType("fastapi")
    class HTTPException(Exception):
        def __init__(self, status_code, detail=None, headers=None):
            self.status_code = status_code
    fa.HTTPException, fa.Request = HTTPException, object
    sys.modules["fastapi"] = fa

from app.security import SlidingWindowLimiter  # noqa: E402


class LimiterTest(unittest.TestCase):
    def test_window(self):
        t = [0.0]
        lim = SlidingWindowLimiter(3, 60, clock=lambda: t[0])
        self.assertTrue(all(lim.allow("a") for _ in range(3)))
        self.assertFalse(lim.allow("a"))
        self.assertTrue(lim.allow("b"))  # outro IP não é afetado
        self.assertGreaterEqual(lim.retry_after("a"), 1)
        t[0] = 61
        self.assertTrue(lim.allow("a"))

    def test_disabled_when_zero(self):
        lim = SlidingWindowLimiter(0)
        self.assertTrue(all(lim.allow("x") for _ in range(1000)))


if __name__ == "__main__":
    unittest.main()
