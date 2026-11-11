"""Google OAuth for installed clients. The server supplies the client secret."""

import logging
import os
import re
from typing import Annotated, Literal

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from ..core.identity import google_oauth_client_ids
from ..security import SlidingWindowLimiter, client_ip, require_api_key

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/auth/google/desktop", tags=["authentication"])
_limiter = SlidingWindowLimiter(20)
_no_store = {"Cache-Control": "no-store"}
_token_url = "https://oauth2.googleapis.com/token"


class DesktopGrant(BaseModel):
    model_config = ConfigDict(extra="forbid")

    client_id: str = Field(min_length=1, max_length=256)


class DesktopCodeGrant(DesktopGrant):
    grant_type: Literal["authorization_code"]
    code: str = Field(min_length=1, max_length=4096)
    code_verifier: str = Field(min_length=43, max_length=128, pattern=r"^[A-Za-z0-9._~-]+$")
    redirect_uri: str = Field(max_length=100, pattern=r"^http://127\.0\.0\.1:[0-9]{1,5}/$")


class DesktopRefreshGrant(DesktopGrant):
    grant_type: Literal["refresh_token"]
    refresh_token: str = Field(min_length=1, max_length=4096)


def _rate_limit(request: Request) -> None:
    key = client_ip(request)
    if not _limiter.allow(key):
        raise HTTPException(
            429, "Aguarde antes de tentar entrar novamente.",
            headers={**_no_store, "Retry-After": str(_limiter.retry_after(key))},
        )


def _error(status: int, code: str) -> HTTPException:
    return HTTPException(status, {"code": code}, headers=_no_store)


async def _exchange_with_google(data: dict[str, str]) -> httpx.Response:
    async with httpx.AsyncClient(timeout=15.0, follow_redirects=False) as client:
        return await client.post(_token_url, data=data)


@router.post("/token", dependencies=[Depends(_rate_limit), Depends(require_api_key)])
async def desktop_google_token(
    grant: Annotated[DesktopCodeGrant | DesktopRefreshGrant, Field(discriminator="grant_type")],
):
    client_id = os.getenv("GOOGLE_DESKTOP_CLIENT_ID", "").strip()
    client_secret = os.getenv("GOOGLE_DESKTOP_CLIENT_SECRET", "").strip()
    if not client_id or not client_secret or client_id not in google_oauth_client_ids():
        raise _error(503, "desktop_oauth_unconfigured")
    if grant.client_id != client_id:
        raise _error(400, "desktop_oauth_client_mismatch")
    if isinstance(grant, DesktopCodeGrant):
        port = re.fullmatch(r"http://127\.0\.0\.1:([0-9]{1,5})/", grant.redirect_uri)
        if not port or not 1 <= int(port.group(1)) <= 65535:
            raise _error(400, "desktop_oauth_invalid_redirect")

    try:
        upstream = await _exchange_with_google({
            **grant.model_dump(),
            "client_secret": client_secret,
        })
        payload = upstream.json()
    except (httpx.HTTPError, ValueError):
        raise _error(502, "desktop_oauth_unavailable") from None

    if not isinstance(payload, dict):
        raise _error(502, "desktop_oauth_unavailable")
    if upstream.status_code != 200:
        reason = payload.get("error")
        if reason in ("invalid_grant", "access_denied"):
            raise _error(401, "desktop_oauth_grant_rejected")
        if reason in ("invalid_client", "unauthorized_client"):
            raise _error(503, "desktop_oauth_unconfigured")
        logger.warning("Desktop Google OAuth recusado (HTTP %d)", upstream.status_code)
        raise _error(502, "desktop_oauth_unavailable")

    id_token = payload.get("id_token")
    if not isinstance(id_token, str) or not id_token:
        raise _error(502, "desktop_oauth_unavailable")
    access_token = payload.get("access_token")
    if isinstance(grant, DesktopCodeGrant) and (
        not isinstance(access_token, str) or not access_token
    ):
        raise _error(502, "desktop_oauth_unavailable")

    tokens = {"id_token": id_token}
    if isinstance(grant, DesktopCodeGrant):
        tokens["access_token"] = access_token
    refresh = payload.get("refresh_token")
    if isinstance(refresh, str) and refresh:
        tokens["refresh_token"] = refresh
    if isinstance(payload.get("expires_in"), int):
        tokens["expires_in"] = payload["expires_in"]
    return JSONResponse(tokens, headers=_no_store)
