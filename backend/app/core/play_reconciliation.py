"""Fase 3I: Google Play RTDN autenticado e reconciliação independente do app.

Nunca usa a notificação como prova de pagamento: consulta subscriptionsv2.get.
Tokens ficam cifrados com chave do Railway somente quando RTDN é habilitado.
A primeira associação de uma compra continua sendo feita pelo cliente autenticado.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import json
import logging
import os
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Any

from . import store_billing as billing
from .account_privacy import deletion_status

logger = logging.getLogger(__name__)
_OIDC_EMAIL = re.compile(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$')


def enabled() -> bool:
    return os.getenv('GAMA_PLAY_RTDN_ENABLED', '0').strip() == '1'


def _fernet():
    from cryptography.fernet import Fernet
    value = os.getenv('GAMA_PLAY_TOKEN_ENCRYPTION_KEY', '').strip()
    try:
        return Fernet(value.encode('ascii'))
    except (ValueError, TypeError, UnicodeEncodeError) as exc:
        raise billing.BillingUnavailable('Chave de criptografia das assinaturas inválida') from exc


def _config() -> tuple[str, str, str]:
    if not enabled():
        raise billing.BillingUnavailable('Notificações da Google Play desativadas')
    package, _products, _secret = billing._configuration()
    audience = os.getenv('GAMA_PLAY_RTDN_AUDIENCE', '').strip()
    service_email = os.getenv('GAMA_PLAY_RTDN_SERVICE_ACCOUNT_EMAIL', '').strip().lower()
    if not audience.startswith('https://') or not _OIDC_EMAIL.fullmatch(service_email):
        raise billing.BillingUnavailable('Pub/Sub ainda não configurado')
    _fernet()  # falha fechada quando a chave não estiver válida
    return package, audience, service_email


def encrypt_token_for_reconciliation(token: str) -> str | None:
    if not enabled():
        return None
    _config()
    return _fernet().encrypt(token.encode('utf-8')).decode('ascii')


def _decrypt(encrypted: str) -> str:
    from cryptography.fernet import InvalidToken
    try:
        token = _fernet().decrypt(encrypted.encode('ascii')).decode('utf-8')
    except (InvalidToken, ValueError, UnicodeError) as exc:
        raise billing.BillingUnavailable('Não foi possível decifrar o token de compra') from exc
    if not billing._TOKEN.fullmatch(token):
        raise billing.BillingUnavailable('Token cifrado inválido')
    return token


def _verify_google_token(raw: str, audience: str) -> dict:
    # A validação faz verificação criptográfica, emissor, público e validade.
    from google.auth.transport.requests import Request
    from google.oauth2 import id_token
    return id_token.verify_oauth2_token(raw, Request(), audience=audience, clock_skew_in_seconds=30)


async def authenticate_push(authorization: str) -> None:
    _package, audience, service_email = _config()
    if not authorization.startswith('Bearer ') or len(authorization) > 16000:
        raise billing.BillingForbidden('Notificação não autenticada')
    token = authorization[7:].strip()
    if not token:
        raise billing.BillingForbidden('Notificação não autenticada')
    try:
        claims = await asyncio.to_thread(_verify_google_token, token, audience)
    except Exception as exc:
        raise billing.BillingForbidden('Identidade Pub/Sub inválida') from exc
    if not isinstance(claims, dict) or (
        not isinstance(claims.get('email'), str)
        or claims['email'].lower() != service_email
        or claims.get('email_verified') not in (True, 'true')
        or claims.get('iss') not in ('https://accounts.google.com', 'accounts.google.com')
        or claims.get('aud') != audience
    ):
        raise billing.BillingForbidden('Identidade Pub/Sub não autorizada')


def _tables(db: sqlite3.Connection):
    db.execute('''CREATE TABLE IF NOT EXISTS play_rtdn_events (
       message_hash TEXT PRIMARY KEY, token_hash TEXT, event_type TEXT NOT NULL,
       status TEXT NOT NULL, created_at TEXT NOT NULL)''')
    db.execute('''CREATE TABLE IF NOT EXISTS play_voided_orders (
       token_hash TEXT NOT NULL, order_hash TEXT NOT NULL,
       created_at TEXT NOT NULL, PRIMARY KEY(token_hash,order_hash))''')


def latest_order_hash(payload: dict) -> str | None:
    # Priorizar último pedido efetivamente pago, não o pedido pendente.
    for line in payload.get('lineItems') or []:
        if isinstance(line, dict) and isinstance(line.get('latestSuccessfulOrderId'), str):
            return hashlib.sha256(line['latestSuccessfulOrderId'].encode()).hexdigest()
    raw = payload.get('latestOrderId')
    return hashlib.sha256(raw.encode()).hexdigest() if isinstance(raw, str) and raw else None


def _order_hashes(payload: dict) -> set[str]:
    identifiers: set[str] = set()
    if isinstance(payload.get('latestOrderId'), str):
        identifiers.add(payload['latestOrderId'])
    for line in payload.get('lineItems') or []:
        if isinstance(line, dict) and isinstance(line.get('latestSuccessfulOrderId'), str):
            identifiers.add(line['latestSuccessfulOrderId'])
    return {hashlib.sha256(v.encode()).hexdigest() for v in identifiers if v}


def order_is_voided(token_hash: str, payload: dict) -> bool:
    if not billing._db_path().exists():
        return False
    orders = _order_hashes(payload)
    if not orders:
        return False
    with billing._connection() as db:
        _tables(db)
        placeholders = ','.join('?' for _ in orders)
        row = db.execute(
            f'SELECT 1 FROM play_voided_orders WHERE token_hash=? AND order_hash IN ({placeholders}) LIMIT 1',
            (token_hash, *orders),
        ).fetchone()
        return bool(row)


def _save_voided_order(token_hash: str, order_id: str):
    with billing._connection() as db:
        _tables(db)
        hashed_order = hashlib.sha256(order_id.encode()).hexdigest()
        db.execute('INSERT OR IGNORE INTO play_voided_orders VALUES(?,?,?)',
                   (token_hash, hashed_order, datetime.now(timezone.utc).isoformat()))
        # Se este é o último pedido já verificado, revogar o acesso imediatamente.
        # Uma renovação posterior com outro pedido poderá restaurá-lo após API Play.
        db.execute("""UPDATE play_checks SET verified_active=0, entitlement_applied=0
                      WHERE token_hash=? AND latest_order_hash=?""", (token_hash, hashed_order))


def _already_processed(msg_hash: str) -> bool:
    if not billing._db_path().exists():
        return False
    with billing._connection() as db:
        _tables(db)
        return db.execute('SELECT 1 FROM play_rtdn_events WHERE message_hash=?', (msg_hash,)).fetchone() is not None


def _event_done(msg_hash: str, token_hash: str | None, event_type: str, status: str) -> None:
    with billing._connection() as db:
        _tables(db)
        db.execute('INSERT OR IGNORE INTO play_rtdn_events VALUES(?,?,?,?,?)',
                   (msg_hash, token_hash, event_type, status, datetime.now(timezone.utc).isoformat()))
        # Sem IDs/compra completos. Limita tabela de eventos a 90 dias.
        cutoff = (datetime.now(timezone.utc) - timedelta(days=90)).isoformat()
        db.execute('DELETE FROM play_rtdn_events WHERE created_at<?', (cutoff,))


def _owner_for_token(token_hash: str) -> str | None:
    if not billing._db_path().exists():
        return None
    with billing._connection() as db:
        row = db.execute('SELECT owner FROM play_checks WHERE token_hash=?', (token_hash,)).fetchone()
        return row[0] if row else None


async def refresh_known(token: str, owner: str, *, encrypted_token: str | None = None) -> dict:
    if deletion_status(owner) != 'active':
        return {'status': 'account_deleted'}
    package, products, secret = billing._configuration()
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    started_at = datetime.now(timezone.utc).isoformat()
    payload = await billing.fetch_subscription(token, package)
    info = billing._verify_payload(payload, owner, products, secret)
    info['latest_order_hash'] = latest_order_hash(payload)
    if order_is_voided(token_hash, payload):
        info['verified_active'] = False
        info['note'] = 'Pedido atual anulado pela Google Play.'
    if billing.entitlements_enabled() and info['verified_active']:
        if payload.get('acknowledgementState') != 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED':
            await billing.acknowledge_subscription(token, package, info['product_id'])
        info['entitlement_applied'] = True
    else:
        info['entitlement_applied'] = False
    linked = payload.get('linkedPurchaseToken')
    linked_hash = hashlib.sha256(linked.encode()).hexdigest() if isinstance(linked, str) and linked else None
    cipher = encrypted_token or encrypt_token_for_reconciliation(token)
    await asyncio.to_thread(billing._save_check, owner, token_hash, info, linked_hash, cipher, started_at)
    return {'status': 'updated', 'active': info['entitlement_applied']}


def _parse_message(envelope: dict) -> tuple[str, dict]:
    message = envelope.get('message')
    if not isinstance(message, dict):
        raise billing.BillingForbidden('Mensagem Pub/Sub inválida')
    msg_id = message.get('messageId') or message.get('message_id')
    encoded = message.get('data')
    if not isinstance(msg_id, str) or not 1 <= len(msg_id) <= 256:
        raise billing.BillingForbidden('Identificador Pub/Sub inválido')
    if not isinstance(encoded, str) or len(encoded) > 40000:
        raise billing.BillingForbidden('Conteúdo Pub/Sub inválido')
    try:
        decoded = base64.b64decode(encoded, validate=True)
        if len(decoded) > 30000:
            raise ValueError('large')
        payload = json.loads(decoded)
    except (ValueError, UnicodeError, binascii.Error) as exc:
        raise billing.BillingForbidden('Evento Pub/Sub inválido') from exc
    if not isinstance(payload, dict):
        raise billing.BillingForbidden('Evento Pub/Sub inválido')
    return msg_id, payload


async def process_push(envelope: dict) -> dict:
    package, _audience, _email = _config()
    msg_id, data = _parse_message(envelope)
    if data.get('packageName') != package:
        raise billing.BillingForbidden('Pacote Google Play incorreto')
    msg_hash = hashlib.sha256(msg_id.encode()).hexdigest()
    if await asyncio.to_thread(_already_processed, msg_hash):
        return {'status': 'duplicate'}
    notification = data.get('subscriptionNotification')
    voided = data.get('voidedPurchaseNotification')
    if 'testNotification' in data:
        await asyncio.to_thread(_event_done, msg_hash, None, 'test', 'acknowledged')
        return {'status': 'test_acknowledged'}
    if isinstance(notification, dict):
        token = notification.get('purchaseToken')
        event_type = f"subscription:{notification.get('notificationType')}"
        void_id = None
    elif isinstance(voided, dict) and voided.get('productType') == 1:
        token = voided.get('purchaseToken')
        event_type = 'voided:subscription'
        void_id = voided.get('orderId')
        if not isinstance(void_id, str) or not 1 <= len(void_id) <= 160:
            raise billing.BillingForbidden('Pedido anulado inválido')
    else:
        # Produtos avulsos não são oferecidos pela Gamma nesta fase.
        await asyncio.to_thread(_event_done, msg_hash, None, 'unsupported', 'ignored')
        return {'status': 'ignored'}
    if not isinstance(token, str) or not billing._TOKEN.fullmatch(token):
        raise billing.BillingForbidden('Token de compra inválido')
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    owner = await asyncio.to_thread(_owner_for_token, token_hash)
    if owner is None or deletion_status(owner) != 'active':
        # Notificação anterior ao vínculo ou posterior à exclusão: não persistir
        # identificadores pessoais nem recriar registros de compra.
        await asyncio.to_thread(_event_done, msg_hash, None, event_type, 'unbound')
        return {'status': 'unbound'}
    if void_id:
        await asyncio.to_thread(_save_voided_order, token_hash, void_id)
    # Exige API Google Play disponível. Em erro transitório responde 503 para
    # o Pub/Sub reentregar, em vez de registrar um falso sucesso.
    result = await refresh_known(token, owner)
    if result['status'] == 'account_deleted':
        await asyncio.to_thread(_event_done, msg_hash, token_hash, event_type, 'account_deleted')
    else:
        await asyncio.to_thread(_event_done, msg_hash, token_hash, event_type, 'processed')
    return {'status': result['status']}


def _claim_due(limit: int, minutes: int) -> list[tuple[str, str, str]]:
    if not billing._db_path().exists():
        return []
    now = datetime.now(timezone.utc)
    cutoff = (now - timedelta(minutes=minutes)).isoformat()
    lease = (now + timedelta(minutes=5)).isoformat()
    with billing._connection() as db:
        db.execute('BEGIN IMMEDIATE')
        rows = db.execute('''SELECT token_hash,owner,encrypted_token FROM play_checks
          WHERE encrypted_token IS NOT NULL AND verified_at<=?
          AND (reconcile_lease_until IS NULL OR reconcile_lease_until<?)
          ORDER BY verified_at ASC LIMIT ?''', (cutoff, now.isoformat(), limit)).fetchall()
        for h, _, _ in rows:
            db.execute('UPDATE play_checks SET reconcile_lease_until=? WHERE token_hash=?', (lease, h))
        return rows


def _release_lease(hashed: str):
    with billing._connection() as db:
        db.execute('UPDATE play_checks SET reconcile_lease_until=NULL WHERE token_hash=?', (hashed,))


async def reconcile_due(limit: int = 20, min_age_minutes: int = 60) -> dict:
    _config()
    if not 1 <= limit <= 50 or not 5 <= min_age_minutes <= 10080:
        raise ValueError('Limites de reconciliação inválidos')
    rows = await asyncio.to_thread(_claim_due, limit, min_age_minutes)
    counters = {'checked': 0, 'failed': 0, 'skipped': 0}
    for hashed, owner, encrypted in rows:
        try:
            token = _decrypt(encrypted)
            if hashlib.sha256(token.encode()).hexdigest() != hashed:
                raise billing.BillingUnavailable('Token cifrado não confere')
            result = await refresh_known(token, owner, encrypted_token=encrypted)
            if result['status'] == 'updated':
                counters['checked'] += 1
            else:
                counters['skipped'] += 1
        except (billing.BillingError, sqlite3.Error, OSError) as exc:
            counters['failed'] += 1
            logger.warning('Reconciliação Play falhou: %s', type(exc).__name__)
        finally:
            await asyncio.to_thread(_release_lease, hashed)
    return counters


def overview() -> dict:
    ready = enabled()
    configured = False
    if ready:
        try:
            _config()
            configured = True
        except billing.BillingError:
            pass
    if not billing._db_path().exists():
        return {'enabled': ready, 'configured': configured, 'tracked': 0, 'reconcilable': 0, 'events_90d': 0}
    with billing._connection() as db:
        _tables(db)
        tracked, reconcilable = db.execute('''SELECT COUNT(*),COUNT(encrypted_token) FROM play_checks''').fetchone()
        events = db.execute('SELECT COUNT(*) FROM play_rtdn_events').fetchone()[0]
        return {'enabled': ready, 'configured': configured,
                'tracked': tracked, 'reconcilable': reconcilable, 'events_90d': events}


def delete_user(owner: str) -> None:
    # Privacidade: remover hashes de mensagens ligadas aos tokens do usuário.
    if not billing._db_path().exists():
        return
    with billing._connection() as db:
        _tables(db)
        tokens = [r[0] for r in db.execute('SELECT token_hash FROM play_checks WHERE owner=?', (owner,))]
        for token in tokens:
            db.execute('DELETE FROM play_rtdn_events WHERE token_hash=?', (token,))
            db.execute('DELETE FROM play_voided_orders WHERE token_hash=?', (token,))


async def periodic_reconcile_loop() -> None:
    try:
        interval = int(os.getenv('GAMA_PLAY_RECONCILE_INTERVAL_MINUTES', '0'))
    except ValueError:
        interval = 0
    if not enabled() or interval < 5:
        return
    while True:
        await asyncio.sleep(interval * 60)
        try:
            result = await reconcile_due(limit=25, min_age_minutes=interval)
            logger.info('Play reconciliation: checked=%s failed=%s', result['checked'], result['failed'])
        except (billing.BillingError, sqlite3.Error, OSError) as exc:
            logger.warning('Play periodic reconciliation unavailable: %s', type(exc).__name__)
