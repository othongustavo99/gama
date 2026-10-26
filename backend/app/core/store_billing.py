"""Fase 3H: verificação Play, reconhecimento e direitos opcionais por usuário.

O cliente nunca escolhe seu plano, valor ou validade. Somente a Google Play
Developer API pode informar o estado de uma compra. Nenhum recibo bruto é
persistido; a chave local é SHA-256 do token (alta entropia). Direitos só são
atribuídos quando habilitados no servidor. Renovação/RTDN ainda são necessários
antes do lançamento público.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import re
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx

_PLAY_SCOPE = 'https://www.googleapis.com/auth/androidpublisher'
_PACKAGE = re.compile(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$')
_PRODUCT = re.compile(r'^[A-Za-z][A-Za-z0-9_.-]{2,120}$')
_TOKEN = re.compile(r'^[A-Za-z0-9._~:-]{16,4096}$')
_ALLOWED_STATES = {
    'SUBSCRIPTION_STATE_ACTIVE',
    'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
    'SUBSCRIPTION_STATE_CANCELED',  # ainda pode existir acesso até o vencimento
}


class BillingError(ValueError):
    pass


class BillingUnavailable(BillingError):
    pass


class BillingForbidden(BillingError):
    pass


class BillingConflict(BillingError):
    pass


def _enabled() -> bool:
    return os.getenv('GAMA_PLAY_VERIFY_ENABLED', '0').strip() == '1'


def checkout_enabled() -> bool:
    return _enabled() and os.getenv('GAMA_PLAY_CHECKOUT_ENABLED', '0').strip() == '1'


def entitlements_enabled() -> bool:
    if not checkout_enabled() or os.getenv('GAMA_PLAY_ENTITLEMENTS_ENABLED', '0').strip() != '1':
        return False
    try:
        _configuration()
        return True
    except BillingUnavailable:
        return False


def _products() -> dict[str, str]:
    """Exemplo de ambiente: gamma_pro_monthly=pro,gamma_creator_monthly=creator."""
    raw = os.getenv('GAMA_PLAY_SUBSCRIPTION_PRODUCTS', '').strip()
    result: dict[str, str] = {}
    if not raw:
        return result
    for entry in raw.split(','):
        parts = entry.strip().split('=')
        if len(parts) != 2:
            raise BillingUnavailable('Catálogo Google Play inválido')
        product, plan = (part.strip() for part in parts)
        if not _PRODUCT.fullmatch(product) or plan not in ('pro', 'creator') or product in result:
            raise BillingUnavailable('Catálogo Google Play inválido')
        result[product] = plan
    return result


def _configuration() -> tuple[str, dict[str, str], str]:
    if not _enabled():
        raise BillingUnavailable('Validação Google Play ainda não habilitada')
    package = os.getenv('GAMA_PLAY_PACKAGE_NAME', '').strip()
    secret = os.getenv('GAMA_PLAY_BINDING_SECRET', '').strip()
    products = _products()
    if not _PACKAGE.fullmatch(package) or len(secret) < 32 or not products:
        raise BillingUnavailable('Configuração Google Play incompleta')
    if not os.getenv('GAMA_PLAY_SERVICE_ACCOUNT_JSON', '').strip():
        raise BillingUnavailable('Credencial de serviço da Google Play ausente')
    return package, products, secret


def readiness() -> dict:
    """Indicadores não sensíveis para o operador; nunca retorna credenciais."""
    package_ok = bool(_PACKAGE.fullmatch(os.getenv('GAMA_PLAY_PACKAGE_NAME', '').strip()))
    try:
        catalog_ok = bool(_products())
    except BillingUnavailable:
        catalog_ok = False
    configured = all([
        package_ok, catalog_ok,
        len(os.getenv('GAMA_PLAY_BINDING_SECRET', '').strip()) >= 32,
        bool(os.getenv('GAMA_PLAY_SERVICE_ACCOUNT_JSON', '').strip()),
    ])
    return {
        'google_play_verification_enabled': _enabled(),
        'google_play_configuration_complete': configured,
        'google_play_ready_for_test': _enabled() and configured,
        'payments_active': entitlements_enabled() and configured,
        'checkout_enabled': checkout_enabled() and configured,
        'entitlements_auto_granted': entitlements_enabled() and configured,
        'microsoft_store_verification_available': False,
        'apple_store_verification_available': False,
    }


def _binding(owner: str, secret: str) -> str:
    return hmac.new(secret.encode('utf-8'), owner.encode('utf-8'), hashlib.sha256).hexdigest()


def account_binding(owner: str) -> dict:
    from .account_privacy import deletion_status
    if deletion_status(owner) != 'active':
        raise BillingForbidden('Conta indisponível')
    _package, _products_map, secret = _configuration()
    return {
        'obfuscated_account_id': _binding(owner, secret),
        'note': 'Usar como obfuscatedAccountId ao iniciar o fluxo oficial Play Billing.',
        'payments_active': entitlements_enabled(),
    }


def _access_token() -> str:
    """Executar fora do loop: token OAuth restrito ao backend, sem expor a chave."""
    try:
        from google.oauth2.service_account import Credentials
        from google.auth.transport.requests import Request
        data = json.loads(os.environ['GAMA_PLAY_SERVICE_ACCOUNT_JSON'])
        if not isinstance(data, dict) or data.get('type') != 'service_account':
            raise ValueError('Tipo inválido')
        cred = Credentials.from_service_account_info(data, scopes=[_PLAY_SCOPE])
        cred.refresh(Request())
        if not cred.token:
            raise ValueError('OAuth sem token')
        return str(cred.token)
    except Exception as exc:
        # Nunca registrar JSON do serviço, tokens ou mensagem bruta da API.
        raise BillingUnavailable('Não foi possível autenticar o serviço Google Play') from exc


async def fetch_subscription(token: str, package: str) -> dict[str, Any]:
    """Consulta independente do cliente; substituível por mock em testes."""
    access_token = await asyncio.to_thread(_access_token)
    safe_token = quote(token, safe='')
    url = (f'https://androidpublisher.googleapis.com/androidpublisher/v3/'
           f'applications/{package}/purchases/subscriptionsv2/tokens/{safe_token}')
    try:
        async with httpx.AsyncClient(timeout=12.0, follow_redirects=False) as client:
            response = await client.get(url, headers={'Authorization': f'Bearer {access_token}'})
    except httpx.HTTPError as exc:
        raise BillingUnavailable('Serviço Google Play temporariamente indisponível') from exc
    if response.status_code != 200:
        # Não expor resposta, URL ou purchase token ao usuário ou log.
        raise BillingUnavailable('Google Play não confirmou esta compra')
    try:
        payload = response.json()
    except ValueError as exc:
        raise BillingUnavailable('Resposta inválida da Google Play') from exc
    if not isinstance(payload, dict):
        raise BillingUnavailable('Resposta inválida da Google Play')
    return payload


def _expiry(value: Any) -> datetime:
    if not isinstance(value, str):
        raise BillingUnavailable('Expiração de assinatura inválida')
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError as exc:
        raise BillingUnavailable('Expiração de assinatura inválida') from exc
    if parsed.tzinfo is None:
        raise BillingUnavailable('Expiração de assinatura sem fuso')
    return parsed.astimezone(timezone.utc)


def _verify_payload(payload: dict, owner: str, products: dict[str, str], secret: str) -> dict:
    linked = payload.get('externalAccountIdentifiers') or {}
    obfuscated = linked.get('obfuscatedExternalAccountId') if isinstance(linked, dict) else None
    # Compra não pode ser apropriada por alguém que apenas conheça o token.
    if not isinstance(obfuscated, str) or not hmac.compare_digest(obfuscated, _binding(owner, secret)):
        raise BillingForbidden('Compra não vinculada a esta conta Gamma')
    lines = payload.get('lineItems')
    if not isinstance(lines, list) or len(lines) != 1 or not isinstance(lines[0], dict):
        raise BillingForbidden('Produto não reconhecido no catálogo Gamma')
    line = lines[0]
    product = line.get('productId')
    if not isinstance(product, str) or product not in products:
        raise BillingForbidden('Produto não reconhecido no catálogo Gamma')
    expires = _expiry(line.get('expiryTime'))
    state = payload.get('subscriptionState')
    active = state in _ALLOWED_STATES and expires > datetime.now(timezone.utc)
    return {
        'product_id': product,
        'plan_preview': products[product],
        'subscription_state': state if isinstance(state, str) else 'UNKNOWN',
        'expires_at': expires.isoformat(),
        'verified_active': active,
        'payments_active': entitlements_enabled(),
        'entitlement_applied': False,
        'note': 'Validação para auditoria; não concede plano, não confirma cobrança.',
    }


def _db_path() -> Path:
    return Path(os.getenv('DATA_DIR', '/data')) / 'gama_play_verification.sqlite3'


@contextmanager
def _connection():
    path = _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=15)
    try:
        db.execute('PRAGMA busy_timeout=15000')
        db.execute('''CREATE TABLE IF NOT EXISTS play_checks (
            token_hash TEXT PRIMARY KEY,
            owner TEXT NOT NULL,
            product TEXT NOT NULL,
            plan_preview TEXT NOT NULL,
            subscription_state TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            verified_active INTEGER NOT NULL,
            verified_at TEXT NOT NULL,
            entitlement_applied INTEGER NOT NULL DEFAULT 0
        )''')
        columns = {row[1] for row in db.execute('PRAGMA table_info(play_checks)')}
        if 'entitlement_applied' not in columns:
            db.execute('ALTER TABLE play_checks ADD COLUMN entitlement_applied INTEGER NOT NULL DEFAULT 0')
        db.execute('CREATE INDEX IF NOT EXISTS ix_play_checks_owner ON play_checks(owner)')
        db.commit()
        yield db
        db.commit()
    except BaseException:
        db.rollback()
        raise
    finally:
        db.close()


def _save_check(owner: str, hashed: str, info: dict, linked_hash: str | None = None) -> bool:
    from .account_privacy import deletion_status
    with _connection() as db:
        db.execute('BEGIN IMMEDIATE')
        if deletion_status(owner) != 'active':
            raise BillingForbidden('Conta excluída ou em exclusão')
        existing = db.execute('SELECT owner FROM play_checks WHERE token_hash=?', (hashed,)).fetchone()
        if linked_hash:
            linked = db.execute('SELECT owner FROM play_checks WHERE token_hash=?', (linked_hash,)).fetchone()
            if linked and linked[0] != owner:
                raise BillingConflict('A assinatura substituída pertence a outra conta')
            if linked:
                db.execute('UPDATE play_checks SET verified_active=0,entitlement_applied=0 WHERE token_hash=?', (linked_hash,))
        if existing and existing[0] != owner:
            raise BillingConflict('Esta compra já está vinculada a outra conta')
        db.execute('''INSERT INTO play_checks
            (token_hash, owner, product, plan_preview, subscription_state, expires_at,
             verified_active, verified_at, entitlement_applied) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(token_hash) DO UPDATE SET
              product=excluded.product,plan_preview=excluded.plan_preview,
              subscription_state=excluded.subscription_state,expires_at=excluded.expires_at,
              verified_active=excluded.verified_active,verified_at=excluded.verified_at,
              entitlement_applied=excluded.entitlement_applied''',
            (hashed, owner, info['product_id'], info['plan_preview'],
             info['subscription_state'], info['expires_at'], int(info['verified_active']),
             datetime.now(timezone.utc).isoformat(), int(info.get('entitlement_applied', False))))
        return bool(existing)


async def acknowledge_subscription(token: str, package: str, product: str) -> None:
    """Reconhece a assinatura no servidor. Erro de rede nunca libera benefícios.

    Chamadas repetidas são toleradas pelo reconhecimento da API Play. Mantemos
    o token somente na memória durante a chamada.
    """
    oauth = await asyncio.to_thread(_access_token)
    url = (f'https://androidpublisher.googleapis.com/androidpublisher/v3/'
           f'applications/{package}/purchases/subscriptions/{product}/tokens/'
           f'{quote(token, safe="")}:acknowledge')
    try:
        async with httpx.AsyncClient(timeout=12.0, follow_redirects=False) as client:
            response = await client.post(url, headers={'Authorization': f'Bearer {oauth}'}, json={})
    except httpx.HTTPError as exc:
        raise BillingUnavailable('Não foi possível reconhecer a assinatura na Google Play') from exc
    if response.status_code not in (200, 204):
        raise BillingUnavailable('A Google Play ainda não confirmou o reconhecimento da compra')


def product_catalog() -> dict:
    ready = readiness()
    if not ready['checkout_enabled'] or not ready['entitlements_auto_granted']:
        return {'available': False, 'products': [], 'reason': 'Assinaturas em preparação'}
    return {'available': True, 'products': [
        {'id': product, 'plan': plan} for product, plan in _products().items()
    ]}


def active_entitlement(owner: str) -> tuple[str, str] | None:
    """Lê o último estado confirmado; vence na data informada pela Play.

    Para produção, RTDN/reconciliação deverá atualizar imediatamente cancelamentos
    excepcionais, reembolsos e renovações. Sem isso a função fica opt-in.
    """
    if not entitlements_enabled() or not _db_path().exists():
        return None
    now = datetime.now(timezone.utc).isoformat()
    with _connection() as db:
        rows = db.execute("""SELECT plan_preview,expires_at FROM play_checks
            WHERE owner=? AND entitlement_applied=1 AND verified_active=1 AND
            expires_at>? ORDER BY expires_at DESC""", (owner, now)).fetchall()
    if not rows:
        return None
    rows.sort(key=lambda row: {'pro': 1, 'creator': 2}.get(row[0], 0), reverse=True)
    return rows[0][0], rows[0][1]


async def verify_subscription(owner: str, token: str) -> dict:
    from .account_privacy import deletion_status
    if deletion_status(owner) != 'active':
        raise BillingForbidden('Conta indisponível')
    if not isinstance(token, str) or not _TOKEN.fullmatch(token):
        raise BillingForbidden('Token de compra inválido')
    package, products, secret = _configuration()
    # Nunca confiar no estado/planos fornecidos pelo dispositivo.
    payload = await fetch_subscription(token, package)
    info = _verify_payload(payload, owner, products, secret)
    # Jamais reconhecer/ativar uma assinatura PENDING, ON_HOLD ou expirada.
    # A ativação requer habilitação explícita em duas etapas no servidor.
    if entitlements_enabled() and info['verified_active']:
        if payload.get('acknowledgementState') != 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED':
            await acknowledge_subscription(token, package, info['product_id'])
        info['entitlement_applied'] = True
        info['note'] = 'Assinatura verificada e reconhecida pela Google Play.'
    hashed = hashlib.sha256(token.encode()).hexdigest()
    linked = payload.get('linkedPurchaseToken')
    linked_hash = hashlib.sha256(linked.encode()).hexdigest() if isinstance(linked, str) and linked else None
    replay = await asyncio.to_thread(_save_check, owner, hashed, info, linked_hash)
    return {**info, 'already_checked': replay}


def history(owner: str) -> list[dict]:
    from .account_privacy import deletion_status
    if deletion_status(owner) != 'active':
        raise BillingForbidden('Conta indisponível')
    if not _db_path().exists():
        return []
    with _connection() as db:
        rows = db.execute('''SELECT product,plan_preview,subscription_state,expires_at,
                            verified_active,verified_at,entitlement_applied FROM play_checks WHERE owner=?
                            ORDER BY verified_at DESC LIMIT 50''', (owner,)).fetchall()
        return [dict(zip(('product_id', 'plan_preview', 'subscription_state', 'expires_at',
                          'verified_active', 'verified_at', 'entitlement_applied'), r)) for r in rows]


def delete_user(owner: str) -> bool:
    if not _db_path().exists():
        return False
    with _connection() as db:
        return db.execute('DELETE FROM play_checks WHERE owner=?', (owner,)).rowcount > 0
