"""3G: nenhuma requisição real à Google Play; simulações determinísticas."""
import asyncio
import hashlib
import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from app.core import identity, store_billing
from app.core.account_privacy import delete_account_data
from app.main import app

OWNER = 'google_email_customer@example.com'
OTHER = 'google_email_other@example.com'
TOKEN = 'PLAY_TEST_TOKEN_123456789123'


@pytest.fixture(autouse=True)
def prepared(tmp_path, monkeypatch):
    monkeypatch.setenv('DATA_DIR', str(tmp_path))
    monkeypatch.setenv('GAMA_REQUIRE_AUTH', '1')
    monkeypatch.setenv('GAMA_PLAY_VERIFY_ENABLED', '1')
    monkeypatch.setenv('GAMA_PLAY_PACKAGE_NAME', 'com.frequencia.gamma')
    monkeypatch.setenv('GAMA_PLAY_SUBSCRIPTION_PRODUCTS', 'gamma_pro_monthly=pro,gamma_creator_monthly=creator')
    monkeypatch.setenv('GAMA_PLAY_BINDING_SECRET', 'valid_but_only_testing_not_for_prod_123')
    monkeypatch.setenv('GAMA_PLAY_SERVICE_ACCOUNT_JSON', '{"type":"service_account"}')

    async def verifier(token):
        if token == 'customer':
            return OWNER
        if token == 'other':
            return OTHER
        raise PermissionError('Sessão inválida')
    monkeypatch.setattr(identity, '_verifier', verifier)
    identity._token_cache.clear()
    yield
    identity._token_cache.clear()


def play_payload(owner=OWNER, state='SUBSCRIPTION_STATE_ACTIVE', hours=48, product='gamma_pro_monthly'):
    return {
        'subscriptionState': state,
        'externalAccountIdentifiers': {'obfuscatedExternalAccountId': store_billing.account_binding(owner)['obfuscated_account_id']},
        'lineItems': [{'productId': product, 'expiryTime': (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()}],
    }


@pytest.mark.asyncio
async def test_verify_and_history_no_token_or_entitlement(monkeypatch):
    async def google(_token, _package):
        return play_payload()
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    result = await store_billing.verify_subscription(OWNER, TOKEN)
    assert result['verified_active'] is True
    assert result['plan_preview'] == 'pro'
    assert result['entitlement_applied'] is False
    assert result['payments_active'] is False
    assert (await store_billing.verify_subscription(OWNER, TOKEN))['already_checked'] is True
    assert len(store_billing.history(OWNER)) == 1
    path = store_billing._db_path()
    assert TOKEN.encode() not in path.read_bytes()
    with sqlite3.connect(path) as db:
        token_hash, owner = db.execute('SELECT token_hash,owner FROM play_checks').fetchone()
        assert token_hash == hashlib.sha256(TOKEN.encode()).hexdigest()
        assert owner == OWNER


@pytest.mark.asyncio
async def test_other_account_cannot_claim_same_purchase(monkeypatch):
    async def google(_token, _package):
        return play_payload(OWNER)
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    await store_billing.verify_subscription(OWNER, TOKEN)
    with pytest.raises(store_billing.BillingForbidden):
        await store_billing.verify_subscription(OTHER, TOKEN)
    assert store_billing.history(OTHER) == []


@pytest.mark.asyncio
@pytest.mark.parametrize('state,hours,active', [
    ('SUBSCRIPTION_STATE_ACTIVE', 1, True),
    ('SUBSCRIPTION_STATE_CANCELED', 2, True),
    ('SUBSCRIPTION_STATE_IN_GRACE_PERIOD', 1, True),
    ('SUBSCRIPTION_STATE_ACTIVE', -2, False),
    ('SUBSCRIPTION_STATE_ON_HOLD', 20, False),
    ('SUBSCRIPTION_STATE_PENDING', 20, False),
])
async def test_states_never_activate_plan(monkeypatch, state, hours, active):
    async def google(_token, _package):
        return play_payload(state=state, hours=hours)
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    result = await store_billing.verify_subscription(OWNER, TOKEN)
    assert result['verified_active'] is active
    assert result['entitlement_applied'] is False
    from app.core.commercial_plans import account_snapshot
    assert account_snapshot(OWNER)['plan'] == 'free'


@pytest.mark.asyncio
async def test_invalid_product_and_binding_fail_closed(monkeypatch):
    for payload in (play_payload(product='unknown_product'), play_payload(owner=OTHER),
                    {'lineItems': [], 'externalAccountIdentifiers': {}}):
        async def google(_token, _package):
            return payload
        monkeypatch.setattr(store_billing, 'fetch_subscription', google)
        with pytest.raises(store_billing.BillingForbidden):
            await store_billing.verify_subscription(OWNER, TOKEN)
    assert not store_billing.history(OWNER)


@pytest.mark.asyncio
async def test_off_by_default_and_missing_config(monkeypatch):
    monkeypatch.setenv('GAMA_PLAY_VERIFY_ENABLED', '0')
    assert store_billing.readiness()['payments_active'] is False
    with pytest.raises(store_billing.BillingUnavailable):
        await store_billing.verify_subscription(OWNER, TOKEN)
    monkeypatch.setenv('GAMA_PLAY_VERIFY_ENABLED', '1')
    monkeypatch.delenv('GAMA_PLAY_BINDING_SECRET')
    with pytest.raises(store_billing.BillingUnavailable):
        store_billing.account_binding(OWNER)


@pytest.mark.asyncio
async def test_provider_failure_does_not_persist(monkeypatch):
    async def google(_token, _package):
        raise store_billing.BillingUnavailable('Indisponível')
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    with pytest.raises(store_billing.BillingUnavailable):
        await store_billing.verify_subscription(OWNER, TOKEN)
    assert not store_billing._db_path().exists()


@pytest.mark.asyncio
async def test_authenticated_routes_no_payment_activation(monkeypatch):
    async def google(_token, _package):
        return play_payload()
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        assert (await client.get('/account/billing/status')).status_code == 401
        headers = {'Authorization': 'Bearer customer'}
        probe = await client.get('/account/billing/status', headers=headers)
        assert probe.status_code == 200 and probe.json()['payments_active'] is False
        binding = await client.get('/account/billing/play/account-binding', headers=headers)
        assert binding.status_code == 200
        assert len(binding.json()['obfuscated_account_id']) == 64
        purchase = await client.post('/account/billing/play/verify', headers=headers,
                                     json={'purchase_token': TOKEN})
        assert purchase.status_code == 200, purchase.text
        hist = await client.get('/account/billing/play/history', headers=headers)
        assert hist.status_code == 200 and len(hist.json()['checks']) == 1
        assert (await client.get('/account/billing/play/history', headers={'Authorization': 'Bearer other'})).json()['checks'] == []
        assert (await client.post('/account/billing/play/verify',
                                  headers={'Authorization': 'Bearer other'},
                                  json={'purchase_token': TOKEN})).status_code == 403


def test_delete_account_clears_billing_verifications():
    info = store_billing._verify_payload(play_payload(), OWNER, store_billing._products(),
                                         'valid_but_only_testing_not_for_prod_123')
    store_billing._save_check(OWNER, hashlib.sha256(TOKEN.encode()).hexdigest(), info)
    result = delete_account_data(OWNER)
    assert result['status'] == 'deleted', result
    with sqlite3.connect(store_billing._db_path()) as db:
        assert db.execute('SELECT COUNT(*) FROM play_checks WHERE owner=?', (OWNER,)).fetchone()[0] == 0
    with pytest.raises(store_billing.BillingForbidden):
        store_billing.account_binding(OWNER)
