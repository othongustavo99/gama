"""Fase 3K: bounded, local-only multi-account ZIP isolation/load exercise.

No external network, real Google tokens, real clients, or paid model calls.
Loads the actual FastAPI application via ASGITransport and uses simulated
identities on a temporary DATA_DIR. Intended for staging/CI, never Railway.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import io
import json
import os
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from unittest.mock import patch

# Running `python scripts/homologate_3k.py` from backend/.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def percentile(samples: list[float], proportion: float) -> float:
    if not samples:
        return 0.0
    samples = sorted(samples)
    return round(samples[min(len(samples) - 1, int((len(samples) - 1) * proportion + 0.999999))], 2)


async def run(users: int = 4, requests: int = 24, concurrency: int = 4) -> dict:
    if not (2 <= users <= 20 and 2 <= requests <= 100 and 1 <= concurrency <= 10):
        raise ValueError('Limites: 2–20 contas, 2–100 trabalhos e 1–10 concorrentes')

    # ALL state is synthetic and scoped to the temp directory.
    with tempfile.TemporaryDirectory(prefix='gamma-3k-simulated-') as temp, patch.dict(os.environ, {
        'DATA_DIR': temp,
        'GAMA_REQUIRE_AUTH': '1',
        'GAMA_REQUIRE_API_KEY': '0',
        'GAMA_API_KEY': '',
        'GAMA_COMMERCIAL_ENFORCEMENT': '0',
        'GAMA_CHAT_MAX_ACTIVE_PER_USER': '0',
        'GAMA_CHAT_MAX_ACTIVE_GLOBAL': '0',
    }):
        import httpx
        from app.main import app
        from app.core import identity

        original = identity._verifier
        old_cache = dict(identity._token_cache)
        identity._token_cache.clear()

        async def verifier(token: str) -> str:
            if not token.startswith('GAMMA-3K-SIMULATED-'):
                raise PermissionError('Não autorizado')
            try:
                index = int(token.rsplit('-', 1)[-1])
            except (TypeError, ValueError):
                raise PermissionError('Não autorizado') from None
            if not 0 <= index < users:
                raise PermissionError('Não autorizado')
            return f'gamma_3k_simulated_user_{index}'

        identity._verifier = verifier
        timings: list[float] = []
        failures: list[str] = []
        sem = asyncio.Semaphore(concurrency)

        def headers(owner: int) -> dict[str, str]:
            return {'Authorization': f'Bearer GAMMA-3K-SIMULATED-{owner}'}

        try:
            transport = httpx.ASGITransport(app=app)
            async with httpx.AsyncClient(transport=transport, base_url='http://gamma-3k.test', timeout=30) as client:
                async def one(number: int) -> None:
                    async with sem:
                        start = time.perf_counter()
                        owner = number % users
                        file_name = f'project_{number:03}.zip'
                        content = f'// conta simulada {owner}, trabalho {number}\nvoid main() {{}}'
                        payload = {'filename': file_name, 'files': {'lib/main.dart': content}}
                        try:
                            response = await client.post('/artifacts/zip/from-files', json=payload, headers=headers(owner))
                            if response.status_code != 200:
                                raise AssertionError(f'create HTTP {response.status_code}')
                            artifact = response.json()
                            download = await client.get(artifact['download_path'], headers=headers(owner))
                            if download.status_code != 200:
                                raise AssertionError(f'download HTTP {download.status_code}')
                            actual_hash = hashlib.sha256(download.content).hexdigest()
                            if actual_hash != artifact['sha256'] or actual_hash != download.headers.get('x-gama-sha256'):
                                raise AssertionError('SHA-256 divergente')
                            with zipfile.ZipFile(io.BytesIO(download.content)) as archive:
                                if archive.read('lib/main.dart').decode() != content:
                                    raise AssertionError('Conteúdo do ZIP divergente')
                            other_owner = (owner + 1) % users
                            denied = await client.get(artifact['download_path'], headers=headers(other_owner))
                            if denied.status_code not in (403, 404):
                                raise AssertionError(f'Acesso cruzado HTTP {denied.status_code}')
                        except Exception as exc:
                            failures.append(f'job {number}: {type(exc).__name__}: {exc}')
                        finally:
                            timings.append((time.perf_counter() - start) * 1000)

                ready = await client.get('/ready')
                await asyncio.gather(*(one(i) for i in range(requests)))
                # Telemetry is intentionally best-effort, but missing entries
                # during a synthetic test indicate operational contention.
                from app.core.commercial_metrics import overview
                metrics = overview(1)['categories'].get('artifacts', {})
                accepted = metrics.get('accepted', 0)
                rejected = metrics.get('client_error', 0)
                if accepted != 2 * requests or rejected != requests:
                    failures.append('Telemetria incompleta sob concorrência: '
                                    f'accepted={accepted}, client_errors={rejected}')
        finally:
            identity._verifier = original
            identity._token_cache.clear()
            identity._token_cache.update(old_cache)

        return {
            'mode': 'in-process ASGI, identities simulated, no paid API calls',
            'users': users,
            'jobs': requests,
            'concurrency': concurrency,
            'readiness_http': ready.status_code,
            'passed': requests - len(failures),
            'failed': len(failures),
            'p50_job_ms': percentile(timings, .5),
            'p95_job_ms': percentile(timings, .95),
            'max_job_ms': round(max(timings, default=0), 2),
            'first_failures': failures[:10],
            'note': 'Measures local ZIP and storage API only; does not simulate paid chat, video generation or production concurrency.',
        }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--users', type=int, default=4)
    parser.add_argument('--jobs', type=int, default=24)
    parser.add_argument('--concurrency', type=int, default=4)
    opts = parser.parse_args(argv)
    result = asyncio.run(run(opts.users, opts.jobs, opts.concurrency))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['failed'] == 0 and result['readiness_http'] == 200 else 2


if __name__ == '__main__':
    raise SystemExit(main())
