"""Telemetria operacional local, limitada e sem conteúdo de usuários.

Indicadores representam apenas o processo atual. Não há credenciais, textos,
query strings nem identificadores de clientes nos rótulos armazenados.
"""
from __future__ import annotations

import os
import threading
import time
from collections import Counter, deque
from statistics import median

_LOCK = threading.Lock()
_MAX_EVENTS = 2500
_EVENTS: deque[tuple[float, str, int, float]] = deque(maxlen=_MAX_EVENTS)
_ALLOWED_GROUPS = frozenset({
    'chat', 'memory', 'conversations', 'extract', 'search', 'project',
    'tts', 'artifacts', 'jobs', 'admin', 'billing', 'account', 'media',
    'models', 'webhooks', 'health', 'ready', 'images', 'video',
})


def route_group(path: str) -> str:
    """Somente grupo estático da URL; nunca guarda path de artefato ou usuário."""
    first = path.split('?', 1)[0].strip('/').split('/', 1)[0].lower()
    return first if first in _ALLOWED_GROUPS else 'other'


def record_response(path: str, status_code: int, elapsed_ms: float) -> None:
    if path in ('/health', '/ready'):
        return
    safe_status = max(100, min(599, int(status_code)))
    with _LOCK:
        _EVENTS.append((time.time(), route_group(path), safe_status, max(0.0, elapsed_ms)))


def _percentile(sorted_values: list[float], percentage: float) -> float:
    if not sorted_values:
        return 0.0
    index = min(len(sorted_values) - 1, max(0, int((len(sorted_values) - 1) * percentage + 0.999999)))
    return round(sorted_values[index], 1)


def snapshot(minutes: int = 15) -> dict:
    minutes = max(1, min(60, int(minutes)))
    cutoff = time.time() - minutes * 60
    with _LOCK:
        entries = [e for e in _EVENTS if e[0] >= cutoff]
    statuses = Counter(f'{status // 100}xx' for _, _, status, _ in entries)
    by_group = Counter(group for _, group, _, _ in entries)
    times = sorted(duration for _, _, _, duration in entries)
    return {
        'window_minutes': minutes,
        'scope': 'this_process_only',
        'requests': len(entries),
        'status_classes': dict(sorted(statuses.items())),
        'route_groups': dict(sorted(by_group.items())),
        'response_header_latency_ms': {
            'p50': _percentile(times, 0.50),
            'p95': _percentile(times, 0.95),
            'max': round(times[-1], 1) if times else 0.0,
        },
        'note': 'Latency measures HTTP response headers; streaming may continue after headers.',
    }
