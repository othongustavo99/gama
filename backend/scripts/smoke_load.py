"""Low-impact HTTP readiness smoke test. Does NOT call paid IA endpoints."""
from __future__ import annotations

import argparse
import json
import statistics
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed


def perform(base_url: str, path: str, timeout: float) -> tuple[int, float]:
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(urllib.parse.urljoin(base_url + '/', path.lstrip('/')), timeout=timeout) as response:
            status = response.status
            response.read(2048)
    except urllib.error.HTTPError as exc:
        status = exc.code
    except (urllib.error.URLError, TimeoutError, OSError):
        status = 0
    return status, (time.perf_counter() - start) * 1000


def run(base_url: str, count: int, concurrency: int, path: str = '/ready', timeout: float = 5.0) -> dict:
    if path not in {'/health', '/ready'}:
        raise ValueError('Only the non-billable /health and /ready endpoints are allowed')
    if not 1 <= count <= 500 or not 1 <= concurrency <= 10 or timeout <= 0:
        raise ValueError('Invalid limits')
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(perform, base_url, path, timeout) for _ in range(count)]
        results = [f.result() for f in as_completed(futures)]
    durations = sorted(ms for _, ms in results)
    success = sum(1 for code, _ in results if 200 <= code < 300)
    return {
        'endpoint': path, 'requests': count, 'concurrency': concurrency,
        'success': success, 'failures': count - success,
        'p50_ms': round(durations[int((len(durations) - 1) * .50)], 1),
        'p95_ms': round(durations[min(len(durations)-1, int((len(durations)-1)*.95+.99999))], 1),
        'max_ms': round(durations[-1], 1),
        'note': 'Health/readiness only; NOT a chat, media, SQLite throughput or paid IA load test.',
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='http://127.0.0.1:8000')
    parser.add_argument('--requests', type=int, default=40)
    parser.add_argument('--concurrency', type=int, default=4)
    parser.add_argument('--path', default='/ready', choices=['/ready', '/health'])
    parser.add_argument('--allow-remote', action='store_true', help='Explicitly allow your production hostname')
    opts = parser.parse_args(argv)
    parsed = urllib.parse.urlsplit(opts.url)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.path not in ('', '/') or parsed.query or parsed.fragment or parsed.username or parsed.password:
        parser.error('URL must be a base HTTP(S) URL without path, credentials or query')
    if parsed.hostname not in ('127.0.0.1', 'localhost', '::1') and not opts.allow_remote:
        parser.error('Remote test requires --allow-remote and permission to test the target')
    output = run(opts.url, opts.requests, opts.concurrency, path=opts.path)
    print(json.dumps(output, indent=2))
    return 0 if output['failures'] == 0 else 2


if __name__ == '__main__':
    raise SystemExit(main())
