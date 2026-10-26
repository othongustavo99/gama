"""3I: Pub/Sub OIDC, RTDN, revogação, criptografia, reconciliação e isolamento.
Mocks determinísticos; nenhuma compra externa, Google Cloud ou chamada paga.
"""
import base64
import hashlib
import json
import sqlite3
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from cryptography.fernet import Fernet

from app.core import store_billing as billing, play_reconciliation as rtdn, commercial_plans
from app.core.account_privacy import delete_account_data
from app.main import app

OWNER = 'google_email_phase3i@example.com'
OTHER = 'google_email_phase3i_other@example.com'
TOKEN = 'PLAY_SUBSCRIPTION_PHASE3I_TOKEN_456123'
PKG = 'com.frequencia.gamma'
ORDER = 'GPA.1234-5678-9012-34567'
AUD = 'https://gamma.example.com/webhooks/google-play/rtdn'
EMAIL = 'pubsub-push@sample-project.iam.gserviceaccount.com'


@pytest.fixture(autouse=True)
def setup(tmp_path, monkeypatch):
    monkeypatch.setenv('DATA_DIR', str(tmp_path))
    monkeypatch.setenv('GAMA_REQUIRE_AUTH', '1')
    monkeypatch.setenv('GAMA_PLAY_VERIFY_ENABLED', '1')
    monkeypatch.setenv('GAMA_PLAY_CHECKOUT_ENABLED', '1')
    monkeypatch.setenv('GAMA_PLAY_ENTITLEMENTS_ENABLED', '1')
    monkeypatch.setenv('GAMA_PLAY_RTDN_ENABLED', '1')
    monkeypatch.setenv('GAMA_PLAY_PACKAGE_NAME', PKG)
    monkeypatch.setenv('GAMA_PLAY_SUBSCRIPTION_PRODUCTS', 'gamma_pro_monthly=pro,gamma_creator_monthly=creator')
    monkeypatch.setenv('GAMA_PLAY_BINDING_SECRET', 'phase3i_secret_for_tests_only_1111222233334444')
    monkeypatch.setenv('GAMA_PLAY_SERVICE_ACCOUNT_JSON', '{"type":"service_account"}')
    monkeypatch.setenv('GAMA_PLAY_TOKEN_ENCRYPTION_KEY', Fernet.generate_key().decode())
    monkeypatch.setenv('GAMA_PLAY_RTDN_AUDIENCE', AUD)
    monkeypatch.setenv('GAMA_PLAY_RTDN_SERVICE_ACCOUNT_EMAIL', EMAIL)
    monkeypatch.setenv('GAMA_PLAY_RECONCILE_INTERVAL_MINUTES', '0')
    monkeypatch.setattr(rtdn, '_verify_google_token', lambda token, audience: {
        'email': EMAIL, 'email_verified': True, 'iss': 'https://accounts.google.com', 'aud': AUD,
    })


def payload(owner=OWNER, state='SUBSCRIPTION_STATE_ACTIVE', hours=48, order=ORDER):
    return {
        'subscriptionState': state,
        'acknowledgementState': 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
        'latestOrderId': order,
        'externalAccountIdentifiers': {
            'obfuscatedExternalAccountId': billing.account_binding(owner)['obfuscated_account_id']},
        'lineItems': [{'productId': 'gamma_pro_monthly', 'latestSuccessfulOrderId': order,
                       'expiryTime': (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()}],
    }


def envelope(notification: dict, message_id='msg-first'):
    encoded = base64.b64encode(json.dumps(notification).encode()).decode()
    return {'message': {'messageId': message_id, 'data': encoded}, 'subscription': 'projects/test/subscriptions/test'}


def subscription_notice(message_id='renew1', event_type=2):
    return envelope({'packageName': PKG, 'subscriptionNotification': {
        'notificationType': event_type, 'purchaseToken': TOKEN}}, message_id)


def void_notice(message_id='void1', order=ORDER):
    return envelope({'packageName': PKG, 'voidedPurchaseNotification': {
        'purchaseToken': TOKEN, 'productType': 1, 'refundType': 1, 'orderId': order}}, message_id)


@pytest.mark.asyncio
async def test_rtdn_push_requires_google_oidc(monkeypatch):
    monkeypatch.setattr(rtdn, '_verify_google_token', lambda *_: {'email': 'intruder@example.com'})
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        notice = envelope({'packageName': PKG, 'testNotification': {'version': '1.0'}})
        assert (await client.post('/webhooks/google-play/rtdn', json=notice)).status_code == 403
        assert (await client.post('/webhooks/google-play/rtdn', json=notice,
                                  headers={'Authorization': 'Bearer fake.jwt'})).status_code == 403


@pytest.mark.asyncio
async def test_pubsub_test_event_is_idempotent_and_wrong_package_is_rejected():
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        h = {'Authorization': 'Bearer dummy-valid-mocked-id-token'}
        notice = envelope({'packageName': PKG, 'testNotification': {'version': '1.0'}}, 'test-1')
        assert (await client.post('/webhooks/google-play/rtdn', json=notice, headers=h)).json()['status'] == 'test_acknowledged'
        assert (await client.post('/webhooks/google-play/rtdn', json=notice, headers=h)).json()['status'] == 'duplicate'
        wrong = envelope({'packageName': 'com.other.app', 'testNotification': {}}, 'test-2')
        assert (await client.post('/webhooks/google-play/rtdn', json=wrong, headers=h)).status_code == 403


@pytest.mark.asyncio
async def test_verified_subscription_records_encrypted_token_and_can_reconcile(monkeypatch):
    current = {'state': 'SUBSCRIPTION_STATE_ACTIVE'}
    async def google(*_):
        return payload(state=current['state'])
    monkeypatch.setattr(billing, 'fetch_subscription', google)
    assert (await billing.verify_subscription(OWNER, TOKEN))['entitlement_applied'] is True
    with sqlite3.connect(billing._db_path()) as db:
        encrypted = db.execute('SELECT encrypted_token FROM play_checks').fetchone()[0]
        assert encrypted and encrypted != TOKEN
        assert TOKEN.encode() not in billing._db_path().read_bytes()
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'pro'
    current['state'] = 'SUBSCRIPTION_STATE_ON_HOLD'
    result = await rtdn.reconcile_due(limit=10, min_age_minutes=5)
    assert result['checked'] == 0  # estado acabou de ser verificado
    # Retrocede o relógio do registro, simulando tarefa esquecida.
    with sqlite3.connect(billing._db_path()) as db:
        db.execute("UPDATE play_checks SET verified_at='2020-01-01T00:00:00+00:00'")
    result = await rtdn.reconcile_due(limit=10, min_age_minutes=5)
    assert result['checked'] == 1
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'


@pytest.mark.asyncio
async def test_subscription_rtdn_refreshes_authoritative_api_and_deduplicates(monkeypatch):
    current = {'state': 'SUBSCRIPTION_STATE_ACTIVE'}
    calls = []
    async def google(*_):
        calls.append(True)
        return payload(state=current['state'])
    monkeypatch.setattr(billing, 'fetch_subscription', google)
    await billing.verify_subscription(OWNER, TOKEN)
    current['state'] = 'SUBSCRIPTION_STATE_EXPIRED'
    result = await rtdn.process_push(subscription_notice())
    assert result['status'] == 'updated'
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'
    assert (await rtdn.process_push(subscription_notice()))['status'] == 'duplicate'
    assert len(calls) == 2


@pytest.mark.asyncio
async def test_unknown_token_never_creates_a_user_or_grants_plan():
    assert (await rtdn.process_push(subscription_notice('unbound'))).get('status') == 'unbound'
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'


@pytest.mark.asyncio
async def test_event_retried_when_google_unavailable(monkeypatch):
    async def first(*_):
        return payload()
    monkeypatch.setattr(billing, 'fetch_subscription', first)
    await billing.verify_subscription(OWNER, TOKEN)
    async def error(*_):
        raise billing.BillingUnavailable('service unavailable')
    monkeypatch.setattr(billing, 'fetch_subscription', error)
    with pytest.raises(billing.BillingUnavailable):
        await rtdn.process_push(subscription_notice('retry-id'))
    assert not rtdn._already_processed(hashlib.sha256(b'retry-id').hexdigest())
    monkeypatch.setattr(billing, 'fetch_subscription', first)
    assert (await rtdn.process_push(subscription_notice('retry-id')))['status'] == 'updated'


@pytest.mark.asyncio
async def test_voided_current_order_blocks_restore_and_old_order_does_not(monkeypatch):
    current = {'order': ORDER}
    async def google(*_):
        return payload(order=current['order'])
    monkeypatch.setattr(billing, 'fetch_subscription', google)
    await billing.verify_subscription(OWNER, TOKEN)
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'pro'
    # Anulação de uma renovação antiga não deve afetar o pedido atual.
    await rtdn.process_push(void_notice('void-old', 'GPA.0000-0000-old'))
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'pro'
    await rtdn.process_push(void_notice('void-current', ORDER))
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'
    assert (await billing.verify_subscription(OWNER, TOKEN))['entitlement_applied'] is False
    # Novo ciclo pago comprovado pela API da Google Play libera novamente.
    current['order'] = 'GPA.2222-3333-4444-55555'
    assert (await billing.verify_subscription(OWNER, TOKEN))['entitlement_applied'] is True


@pytest.mark.asyncio
async def test_rtdn_disabled_returns_503_and_does_not_write(monkeypatch):
    monkeypatch.setenv('GAMA_PLAY_RTDN_ENABLED', '0')
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        result = await client.post('/webhooks/google-play/rtdn', json=subscription_notice(),
                                   headers={'Authorization': 'Bearer token'})
        assert result.status_code == 503
    assert not billing._db_path().exists()


@pytest.mark.asyncio
async def test_bad_encryption_key_fails_closed(monkeypatch):
    monkeypatch.setenv('GAMA_PLAY_TOKEN_ENCRYPTION_KEY', 'guessable')
    with pytest.raises(billing.BillingUnavailable):
        rtdn.encrypt_token_for_reconciliation(TOKEN)


@pytest.mark.asyncio
async def test_deleted_account_not_recreated_by_late_notification(monkeypatch):
    async def google(*_):
        return payload()
    monkeypatch.setattr(billing, 'fetch_subscription', google)
    await billing.verify_subscription(OWNER, TOKEN)
    assert delete_account_data(OWNER)['status'] == 'deleted'
    assert (await rtdn.process_push(subscription_notice('after-delete')))['status'] == 'unbound'
    with pytest.raises(commercial_plans.CommercialError):
        commercial_plans.account_snapshot(OWNER)


def test_old_schema_gets_migrated():
    path = billing._db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as db:
        db.execute('''CREATE TABLE play_checks (token_hash TEXT PRIMARY KEY, owner TEXT NOT NULL,
            product TEXT NOT NULL, plan_preview TEXT NOT NULL, subscription_state TEXT NOT NULL,
            expires_at TEXT NOT NULL, verified_active INTEGER NOT NULL, verified_at TEXT NOT NULL)''')
    with billing._connection() as db:
        columns = {r[1] for r in db.execute('PRAGMA table_info(play_checks)')}
        assert {'encrypted_token', 'latest_order_hash', 'reconcile_lease_until', 'entitlement_applied'} <= columns


@pytest.mark.asyncio
async def test_canceled_but_valid_keeps_access_until_expiration(monkeypatch):
    async def google(*_):
        return payload(state='SUBSCRIPTION_STATE_CANCELED', hours=2)
    monkeypatch.setattr(billing, 'fetch_subscription', google)
    assert (await billing.verify_subscription(OWNER, TOKEN))['entitlement_applied']
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'pro'


@pytest.mark.asyncio
async def test_unbound_refund_creates_no_purchase_marker():
    assert (await rtdn.process_push(void_notice('unbound-void')))['status'] == 'unbound'
    with sqlite3.connect(billing._db_path()) as db:
        count = db.execute('SELECT COUNT(*) FROM play_voided_orders').fetchone()[0]
        assert count == 0
        assert db.execute('SELECT token_hash FROM play_rtdn_events').fetchone()[0] is None


def test_stale_provider_response_cannot_regrant_after_newer_verification():
    from datetime import datetime, timedelta, timezone
    info = billing._verify_payload(payload(), OWNER, billing._products(),
                                   'phase3i_secret_for_tests_only_1111222233334444')
    hashed = hashlib.sha256(TOKEN.encode()).hexdigest()
    old_start = (datetime.now(timezone.utc)-timedelta(minutes=4)).isoformat()
    billing._save_check(OWNER, hashed, {**info, 'entitlement_applied': False})
    newer = billing._verify_payload(payload(state='SUBSCRIPTION_STATE_ON_HOLD'), OWNER,
                                    billing._products(), 'phase3i_secret_for_tests_only_1111222233334444')
    billing._save_check(OWNER, hashed, {**newer, 'entitlement_applied': False})
    billing._save_check(OWNER, hashed, {**info, 'entitlement_applied': True}, started_at=old_start)
    assert commercial_plans.account_snapshot(OWNER)['plan'] == 'free'


@pytest.mark.asyncio
async def test_admin_reconciliation_requires_explicit_allowlist(monkeypatch):
    from app.core import identity
    admin_id = identity.canonical_google_user_id(google_id='', email='gamma.admin3i@example.com')
    user_id = identity.canonical_google_user_id(google_id='', email='gamma.user3i@example.com')
    async def verify(t):
        return admin_id if t == 'admin3i' else user_id
    monkeypatch.setattr(identity, '_verifier', verify)
    identity._token_cache.clear()
    monkeypatch.setenv('GAMA_ADMIN_GOOGLE_EMAILS', 'gamma.admin3i@example.com')
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        route = '/admin/play/reconciliation'
        assert (await client.get(route)).status_code == 401
        assert (await client.get(route, headers={'Authorization': 'Bearer user3i'})).status_code == 403
        answer = await client.get(route, headers={'Authorization': 'Bearer admin3i'})
        assert answer.status_code == 200
        assert answer.json()['enabled'] is True
    identity._token_cache.clear()
