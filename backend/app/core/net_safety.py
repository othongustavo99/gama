"""Proteção contra SSRF para qualquer fetch de URL vinda do usuário ou do modelo.

Regras:
- só http/https, sem credenciais embutidas (user:senha@host);
- só portas web comuns;
- o host precisa resolver SOMENTE para IPs públicos (bloqueia localhost, redes
  privadas, link-local/metadata de nuvem 169.254.x.x, CGNAT etc.);
- redirects são seguidos manualmente e cada salto é revalidado;
- corpo da resposta lido em stream com teto de bytes (evita estourar memória).
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from typing import Iterable
from urllib.parse import urljoin, urlparse

ALLOWED_PORTS = {80, 443, 8080, 8443}
BLOCKED_HOSTNAMES = {
    "localhost",
    "metadata",
    "metadata.google.internal",
    "host.docker.internal",
    "kubernetes.default",
}
BLOCKED_SUFFIXES = (".local", ".internal", ".localhost", ".lan", ".home", ".corp")
DEFAULT_MAX_BYTES = 1_500_000


class UnsafeURLError(ValueError):
    """URL recusada pela política de segurança."""


def is_public_ip(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return bool(ip.is_global and not ip.is_multicast)


def _check_ips(host: str, ips: Iterable[str]) -> None:
    found = False
    for raw in ips:
        found = True
        try:
            ip = ipaddress.ip_address(raw.split("%", 1)[0])
        except ValueError as exc:
            raise UnsafeURLError(f"IP inválido para {host}") from exc
        if not is_public_ip(ip):
            raise UnsafeURLError(f"endereço não público bloqueado ({host})")
    if not found:
        raise UnsafeURLError(f"host sem endereço: {host}")


def validate_url_syntax(url: str) -> tuple[str, str, int]:
    """Valida esquema/host/porta sem tocar na rede. Retorna (scheme, host, port)."""
    try:
        parsed = urlparse((url or "").strip())
        port = parsed.port
    except ValueError as exc:
        raise UnsafeURLError("URL malformada") from exc

    scheme = (parsed.scheme or "").lower()
    if scheme not in {"http", "https"}:
        raise UnsafeURLError("somente http/https são permitidos")
    if parsed.username or parsed.password:
        raise UnsafeURLError("URL com credenciais não é permitida")

    host = (parsed.hostname or "").strip().lower().rstrip(".")
    if not host:
        raise UnsafeURLError("URL sem host")
    if host in BLOCKED_HOSTNAMES or host.endswith(BLOCKED_SUFFIXES):
        raise UnsafeURLError("host interno bloqueado")

    port = port or (443 if scheme == "https" else 80)
    if port not in ALLOWED_PORTS:
        raise UnsafeURLError(f"porta {port} não permitida")

    # IP literal: valida direto, sem DNS.
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None:
        _check_ips(host, [str(literal)])
    return scheme, host, port


def _resolve(host: str, port: int) -> list[str]:
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    return [info[4][0] for info in infos]


async def validate_public_url(url: str) -> str:
    """Valida sintaxe + resolve DNS e exige IPs públicos. Retorna a URL limpa."""
    _scheme, host, port = validate_url_syntax(url)
    try:
        ipaddress.ip_address(host)
        return url.strip()  # IP literal já validado
    except ValueError:
        pass
    try:
        ips = await asyncio.to_thread(_resolve, host, port)
    except socket.gaierror as exc:
        raise UnsafeURLError(f"não foi possível resolver {host}") from exc
    _check_ips(host, ips)
    return url.strip()


async def safe_get(
    client,
    url: str,
    *,
    max_bytes: int = DEFAULT_MAX_BYTES,
    max_redirects: int = 4,
    headers: dict | None = None,
):
    """GET seguro. `client` é um httpx.AsyncClient (follow_redirects=False).

    Retorna (url_final, status_code, content_type, corpo_em_bytes).
    Levanta UnsafeURLError se qualquer salto violar a política.
    """
    current = url
    for _ in range(max_redirects + 1):
        await validate_public_url(current)
        async with client.stream(
            "GET", current, headers=headers, follow_redirects=False
        ) as resp:
            if resp.status_code in (301, 302, 303, 307, 308):
                location = resp.headers.get("location")
                if not location:
                    raise UnsafeURLError("redirect sem Location")
                current = urljoin(current, location)
                continue

            chunks: list[bytes] = []
            total = 0
            async for chunk in resp.aiter_bytes():
                total += len(chunk)
                if total > max_bytes:
                    chunks.append(chunk[: max(0, max_bytes - (total - len(chunk)))])
                    break
                chunks.append(chunk)
            ctype = (resp.headers.get("content-type") or "").lower()
            return current, resp.status_code, ctype, b"".join(chunks)
    raise UnsafeURLError("redirects demais")
