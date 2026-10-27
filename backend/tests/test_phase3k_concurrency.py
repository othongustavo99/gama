"""Fase 3K: no-paid-provider concurrency, recovery and isolation regressions."""
from __future__ import annotations

import asyncio
import importlib
import json
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import HTTPException

from app.core.chat_admission import AdmissionRejected, ChatAdmissionRegistry, chat_admissions
from app.models import ChatMessage, ChatRequest


def test_duplicate_reservations_are_atomic_across_threads(monkeypatch):
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_PER_USER', '0')
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_GLOBAL', '0')
    registry = ChatAdmissionRegistry()

    def attempt(_):
        try:
            return registry.reserve('account-A', 'same-message')
        except AdmissionRejected as exc:
            return exc.status_code

    with ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(attempt, range(40)))
    leases = [r for r in results if not isinstance(r, int)]
    assert len(leases) == 1
    assert results.count(409) == 39
    assert registry.snapshot() == {'active': 1, 'active_users': 1}
    leases[0].release()
    leases[0].release()  # idempotent
    assert registry.snapshot() == {'active': 0, 'active_users': 0}


def test_optional_limits_keep_users_isolated_and_release_slots(monkeypatch):
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_PER_USER', '2')
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_GLOBAL', '3')
    registry = ChatAdmissionRegistry()
    a1 = registry.reserve('account-A', 'first')
    a2 = registry.reserve('account-A', 'second')
    with pytest.raises(AdmissionRejected) as exc:
        registry.reserve('account-A', 'third')
    assert exc.value.status_code == 429
    b1 = registry.reserve('account-B', 'first')
    with pytest.raises(AdmissionRejected) as exc:
        registry.reserve('account-C', 'first')
    assert exc.value.status_code == 503
    assert 'account-A' not in str(registry.snapshot())
    a1.release()
    c1 = registry.reserve('account-C', 'first')
    c1.release()
    b1.release()
    a2.release()
    assert registry.snapshot()['active'] == 0


def test_invalid_limit_configuration_is_rejected(monkeypatch):
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_PER_USER', 'invalid')
    with pytest.raises(ValueError):
        ChatAdmissionRegistry().reserve('a', 'm')


@pytest.mark.asyncio
async def test_chat_reserves_id_before_stream_consumption(monkeypatch, tmp_path):
    monkeypatch.setenv('DATA_DIR', str(tmp_path))
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_PER_USER', '0')
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_GLOBAL', '0')
    mod = importlib.import_module('app.routes.chat')
    started, complete = asyncio.Event(), asyncio.Event()

    async def fake_llm(*, model, messages):
        started.set()
        yield json.dumps({'message': {'role': 'assistant', 'content': 'iniciado'}, 'done': False}) + '\n'
        await complete.wait()
        yield json.dumps({'message': {'role': 'assistant', 'content': 'concluído'}, 'done': True}) + '\n'

    request = ChatRequest(model='openai/gpt-5.4-mini', chat_mode='conversar',
                          assistant_message_id='phase3k-atomic-id', conversation_id='phase3k-conv',
                          messages=[ChatMessage(role='user', content='Oi')],
                          auto_memory=False, plugins={'memory': False, 'web_search': False})
    with (patch.object(mod.app_settings, 'AGENT_TOOLS_ENABLED', False),
          patch.object(mod.gama, 'build_messages', new=AsyncMock(return_value=(
              [{'role': 'user', 'content': 'Oi'}], None, None, []))),
          patch.object(mod.llm, 'stream_chat', new=fake_llm),
          patch.object(mod, 'schedule_summary_refresh', return_value=None)):
        response = await mod.chat(request, user_id='phase3k-user')
        assert chat_admissions.snapshot()['active'] >= 1
        with pytest.raises(HTTPException) as exc:
            await mod.chat(request, user_id='phase3k-user')
        assert exc.value.status_code == 409
        try:
            await asyncio.wait_for(response.body_iterator.__anext__(), timeout=6)
            await asyncio.wait_for(started.wait(), timeout=6)
        finally:
            complete.set()
            await response.body_iterator.aclose()
        # Producer intentionally continues after disconnect; callback releases
        # admission only when the server has finished the generation.
        for _ in range(150):
            if chat_admissions.snapshot()['active'] == 0:
                break
            await asyncio.sleep(.03)
        assert chat_admissions.snapshot()['active'] == 0


@pytest.mark.asyncio
async def test_admission_is_released_if_quota_rejects_request(monkeypatch):
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_PER_USER', '0')
    mod = importlib.import_module('app.routes.chat')
    request = ChatRequest(model='openai/gpt-5.4-mini', chat_mode='conversar',
                          assistant_message_id='phase3k-rollback-id',
                          messages=[ChatMessage(role='user', content='Oi')],
                          auto_memory=False, plugins={'memory': False, 'web_search': False})
    before = chat_admissions.snapshot()['active']
    with patch.object(mod, 'reserve_feature', side_effect=mod.FeatureLimitReached('cota esgotada')):
        with pytest.raises(HTTPException) as exc:
            await mod.chat(request, user_id='phase3k-quota-owner')
    assert exc.value.status_code == 429
    assert chat_admissions.snapshot()['active'] == before


@pytest.mark.asyncio
async def test_offline_homologation_really_uses_distinct_identities(monkeypatch):
    script = importlib.import_module('scripts.homologate_3k')
    result = await script.run(users=3, requests=9, concurrency=3)
    assert result['failed'] == 0, result
    assert result['passed'] == 9
    assert result['readiness_http'] == 200
    assert result['mode'].startswith('in-process')


@pytest.mark.asyncio
async def test_provider_failure_does_not_hold_capacity_forever(monkeypatch, tmp_path):
    """A broken paid provider must not leave a permanent admission reservation."""
    monkeypatch.setenv('DATA_DIR', str(tmp_path))
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_PER_USER', '0')
    monkeypatch.setenv('GAMA_CHAT_MAX_ACTIVE_GLOBAL', '0')
    mod = importlib.import_module('app.routes.chat')

    async def failed_llm(*, model, messages):
        raise RuntimeError('provável indisponibilidade simulada')
        yield ''  # async generator, never calls a real provider

    request = ChatRequest(model='openai/gpt-5.4-mini', chat_mode='conversar',
                          assistant_message_id='phase3k-provider-failure-id',
                          messages=[ChatMessage(role='user', content='Teste')],
                          auto_memory=False, plugins={'memory': False, 'web_search': False})
    with (patch.object(mod.app_settings, 'AGENT_TOOLS_ENABLED', False),
          patch.object(mod.gama, 'build_messages', new=AsyncMock(return_value=(
              [{'role': 'user', 'content': 'Teste'}], None, None, []))),
          patch.object(mod.llm, 'stream_chat', new=failed_llm),
          patch.object(mod, 'schedule_summary_refresh', return_value=None)):
        response = await mod.chat(request, user_id='phase3k-failure-account')
        output = []
        async for chunk in response.body_iterator:
            output.append(chunk)
        assert any('done' in str(c) or 'error' in str(c) for c in output)
        for _ in range(100):
            if chat_admissions.snapshot()['active'] == 0:
                break
            await asyncio.sleep(.03)
        assert chat_admissions.snapshot()['active'] == 0


def test_concurrent_activity_metrics_are_not_lost(tmp_path, monkeypatch):
    monkeypatch.setenv('DATA_DIR', str(tmp_path))
    from app.core.commercial_metrics import overview, record_request

    def write(i):
        record_request(f'gamma_3k_owner_{i % 5}', '/artifacts/zip/from-files', 200)

    with ThreadPoolExecutor(max_workers=12) as pool:
        list(pool.map(write, range(96)))
    totals = overview(1)['categories']['artifacts']
    assert totals['accepted'] == 96
