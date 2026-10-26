"""Verifica concessão condicional, reconhecimento, vínculo e migração de SQLite.
Nenhuma chamada à Play: mocks no backend. Requer chave fictícia do OpenRouter.
"""
import hashlib
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

from app.core import store_billing, commercial_plans

OWNER = 'google_email_test3h@example.com'
OTHER = 'google_email_other3h@example.com'
TOKEN = 'TOKEN_PHASE3H_VALID_1234567890'


@pytest.fixture(autouse=True)
def settings(tmp_path, monkeypatch):
    monkeypatch.setenv('DATA_DIR', str(tmp_path))
    monkeypatch.setenv('GAMA_REQUIRE_AUTH', '1')
    monkeypatch.setenv('GAMA_PLAY_VERIFY_ENABLED', '1')
    monkeypatch.setenv('GAMA_PLAY_CHECKOUT_ENABLED', '1')
    monkeypatch.setenv('GAMA_PLAY_ENTITLEMENTS_ENABLED', '1')
    monkeypatch.setenv('GAMA_PLAY_PACKAGE_NAME', 'com.frequencia.gamma')
    monkeypatch.setenv('GAMA_PLAY_SUBSCRIPTION_PRODUCTS', 'gamma_pro_monthly=pro,gamma_creator_monthly=creator')
    monkeypatch.setenv('GAMA_PLAY_BINDING_SECRET', 'valid_but_only_testing_not_for_prod_123')
    monkeypatch.setenv('GAMA_PLAY_SERVICE_ACCOUNT_JSON', '{"type":"service_account"}')


def payload(owner=OWNER, state='SUBSCRIPTION_STATE_ACTIVE', expiry_hours=48,
            product='gamma_pro_monthly', **extra):
    return {
        'subscriptionState': state,
        'acknowledgementState': 'ACKNOWLEDGEMENT_STATE_PENDING',
        'externalAccountIdentifiers': {
            'obfuscatedExternalAccountId': store_billing.account_binding(owner)['obfuscated_account_id'],
        },
        'lineItems': [{'productId': product, 'expiryTime':
                       (datetime.now(timezone.utc) + timedelta(hours=expiry_hours)).isoformat()}],
        **extra,
    }


@pytest.mark.asyncio
async def test_grants_only_after_backend_ack(monkeypatch):
    async def google(*_):
        return payload()
    async def ack(*_):
        calls.append(True)
    calls = []
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    monkeypatch.setattr(store_billing, 'acknowledge_subscription', ack)
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'
    outcome = await store_billing.verify_subscription(OWNER, TOKEN)
    assert outcome['verified_active'] and outcome['entitlement_applied']
    assert calls == [True]
    snapshot = commercial_plans.account_snapshot(OWNER)
    assert snapshot['plan'] == 'pro'
    assert snapshot['plan_expires_at'] == outcome['expires_at']
    assert (await store_billing.verify_subscription(OWNER, TOKEN))['already_checked']
    assert len(store_billing.history(OWNER)) == 1
    assert TOKEN.encode() not in store_billing._db_path().read_bytes()


@pytest.mark.asyncio
async def test_no_entitlement_on_failed_ack(monkeypatch):
    async def google(*_):
        return payload()
    async def ack(*_):
        raise store_billing.BillingUnavailable('Test')
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    monkeypatch.setattr(store_billing, 'acknowledge_subscription', ack)
    with pytest.raises(store_billing.BillingUnavailable):
        await store_billing.verify_subscription(OWNER, TOKEN)
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'


@pytest.mark.asyncio
@pytest.mark.parametrize('state,expiry', [
    ('SUBSCRIPTION_STATE_PENDING', 48), ('SUBSCRIPTION_STATE_ON_HOLD', 48),
    ('SUBSCRIPTION_STATE_EXPIRED', 48), ('SUBSCRIPTION_STATE_ACTIVE', -1),
])
async def test_pending_on_hold_expired_never_granted(monkeypatch, state, expiry):
    async def google(*_):
        return payload(state=state, expiry_hours=expiry)
    async def ack(*_):
        raise AssertionError('Não reconhecer assinatura inválida')
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    monkeypatch.setattr(store_billing, 'acknowledge_subscription', ack)
    result = await store_billing.verify_subscription(OWNER, TOKEN)
    assert not result['verified_active'] and not result['entitlement_applied']
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'


@pytest.mark.asyncio
async def test_switch_owner_is_rejected(monkeypatch):
    async def google(*_):
        return payload(OWNER)
    async def ack(*_):
        pass
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    monkeypatch.setattr(store_billing, 'acknowledge_subscription', ack)
    with pytest.raises(store_billing.BillingForbidden):
        await store_billing.verify_subscription(OTHER, TOKEN)
    assert commercial_plans.account_snapshot(OTHER)['plan'] == 'free'


@pytest.mark.asyncio
async def test_linked_purchase_replaces_old_entitlement(monkeypatch):
    token2 = 'TOKEN_PHASE3H_NEW_987654321123'
    async def ack(*_):
        pass
    monkeypatch.setattr(store_billing, 'acknowledge_subscription', ack)
    async def original(*_):
        return payload(product='gamma_creator_monthly')
    monkeypatch.setattr(store_billing, 'fetch_subscription', original)
    await store_billing.verify_subscription(OWNER, TOKEN)
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'creator'
    async def replacement(*_):
        return payload(product='gamma_pro_monthly', linkedPurchaseToken=TOKEN)
    monkeypatch.setattr(store_billing, 'fetch_subscription', replacement)
    await store_billing.verify_subscription(OWNER, token2)
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'pro'
    with sqlite3.connect(store_billing._db_path()) as db:
        assert db.execute('SELECT entitlement_applied FROM play_checks WHERE token_hash=?',
                          (hashlib.sha256(TOKEN.encode()).hexdigest(),)).fetchone() == (0,)


@pytest.mark.asyncio
async def test_disable_flags_does_not_grant(monkeypatch):
    monkeypatch.setenv('GAMA_PLAY_ENTITLEMENTS_ENABLED', '0')
    assert not store_billing.product_catalog()['available']
    async def google(*_):
        return payload()
    monkeypatch.setattr(store_billing, 'fetch_subscription', google)
    result = await store_billing.verify_subscription(OWNER, TOKEN)
    assert result['entitlement_applied'] is False
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'


def test_migrates_existing_3g_database():
    path = store_billing._db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as db:
        db.execute('''CREATE TABLE play_checks (
            token_hash TEXT PRIMARY KEY, owner TEXT NOT NULL, product TEXT NOT NULL,
            plan_preview TEXT NOT NULL, subscription_state TEXT NOT NULL,
            expires_at TEXT NOT NULL, verified_active INTEGER NOT NULL,
            verified_at TEXT NOT NULL)''')
    with store_billing._connection() as db:
        columns = {r[1] for r in db.execute('PRAGMA table_info(play_checks)')}
        assert 'entitlement_applied' in columns
