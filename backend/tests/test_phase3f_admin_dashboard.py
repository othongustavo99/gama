"""3F: operações beta por e-mail com autorização real e idempotência."""
import httpx
import pytest

from app.core import identity
from app.main import app


@pytest.fixture(autouse=True)
def setup(tmp_path, monkeypatch):
    monkeypatch.setenv('DATA_DIR', str(tmp_path))
    monkeypatch.setenv('GAMA_REQUIRE_AUTH', '1')
    monkeypatch.setenv('GAMA_ADMIN_GOOGLE_EMAILS', 'admin@example.com')
    async def verify(token):
        if token == 'admin':
            return 'google_email_admin@example.com'
        if token == 'client':
            return 'google_email_customer@example.com'
        raise PermissionError('invalid')
    monkeypatch.setattr(identity, '_verifier', verify)
    identity._token_cache.clear()
    yield
    identity._token_cache.clear()


@pytest.mark.asyncio
async def test_admin_access_never_uses_client_header():
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as c:
        assert (await c.get('/admin/access', headers={'X-User-Id': 'google_email_admin@example.com'})).status_code == 401
        assert (await c.get('/admin/access', headers={'Authorization': 'Bearer client'})).status_code == 403
        r = await c.get('/admin/access', headers={'Authorization': 'Bearer admin'})
        assert r.status_code == 200
        assert r.json() == {'is_admin': True, 'payments_active': False}


@pytest.mark.asyncio
async def test_account_lookup_and_idempotent_operations():
    admin = {'Authorization': 'Bearer admin'}
    client = {'Authorization': 'Bearer client'}
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as c:
        lookup = {'email': ' Customer@Example.COM '}
        r = await c.post('/admin/commercial/account-by-email', json=lookup, headers=client)
        assert r.status_code == 403
        r = await c.post('/admin/commercial/account-by-email', json=lookup, headers=admin)
        assert r.status_code == 200, r.text
        assert r.json()['account_id'] == 'google_email_customer@example.com'
        assert r.json()['plan'] == 'free'
        assert 'não comprova' in r.json()['lookup_note'].lower()
        plan = {'email': lookup['email'], 'plan': 'pro', 'duration_days': 30,
                'request_id': '3f_unique_plan_123'}
        r = await c.post('/admin/commercial/assign-plan-by-email', json=plan, headers=admin)
        assert r.status_code == 200, r.text
        r = await c.post('/admin/commercial/assign-plan-by-email', json=plan, headers=admin)
        assert r.status_code == 200 and r.json()['idempotent_replay'] is True
        credits = {'email': lookup['email'], 'delta': 15, 'reason': 'teste_beta',
                   'request_id': '3f_unique_credits_123'}
        r = await c.post('/admin/commercial/adjust-credits-by-email', json=credits, headers=admin)
        assert r.status_code == 200, r.text
        assert r.json()['credits_balance'] == 15
        r = await c.post('/admin/commercial/adjust-credits-by-email', json=credits, headers=admin)
        assert r.json()['credits_balance'] == 15
        r = await c.post('/admin/commercial/account-by-email', json=lookup, headers=admin)
        assert r.json()['plan'] == 'pro' and r.json()['credits_balance'] == 15
        assert (await c.post('/admin/commercial/account-by-email', json={'email': '../'}, headers=admin)).status_code == 422
        assert (await c.post('/admin/commercial/assign-plan-by-email', json={**plan, 'plan': 'creator'}, headers=admin)).status_code == 409


@pytest.mark.asyncio
async def test_reject_non_admin_changes_without_mutating_data():
    admin = {'Authorization': 'Bearer admin'}
    client = {'Authorization': 'Bearer client'}
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as c:
        args = {'email': 'customer@example.com', 'delta': 20, 'reason': 'teste_beta',
                'request_id': '3f_try_client_123'}
        assert (await c.post('/admin/commercial/adjust-credits-by-email', json=args, headers=client)).status_code == 403
        result = await c.post('/admin/commercial/account-by-email', json={'email': args['email']}, headers=admin)
        assert result.json()['credits_balance'] == 0
