"""Stub mínimo do httpx para rodar os testes unitários sem dependências instaladas."""
import sys
import types

try:  # pragma: no cover
    import httpx  # noqa: F401
except ModuleNotFoundError:
    m = types.ModuleType("httpx")

    class _Err(Exception):
        pass

    for name in ("ConnectError", "ConnectTimeout", "ReadTimeout", "RemoteProtocolError", "PoolTimeout",
                 "TransportError", "HTTPStatusError"):
        setattr(m, name, type(name, (_Err,), {}))

    class _Dummy:
        def __init__(self, *a, **k):
            self.is_closed = False

    m.Timeout = _Dummy
    m.Limits = _Dummy
    m.AsyncClient = _Dummy
    sys.modules["httpx"] = m
