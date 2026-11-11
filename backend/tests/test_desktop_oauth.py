import os
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.routes.desktop_oauth import router
from app.security import require_api_key


class DesktopGoogleOAuthTest(unittest.TestCase):
    def setUp(self):
        app = FastAPI()
        app.include_router(router)
        app.dependency_overrides[require_api_key] = lambda: None
        self.http = TestClient(app)
        env = patch.dict(os.environ, {
            "GOOGLE_DESKTOP_CLIENT_ID": "desktop.apps.googleusercontent.com",
            "GOOGLE_DESKTOP_CLIENT_SECRET": "server-only-secret",
            "GOOGLE_OAUTH_CLIENT_IDS": "web.apps.googleusercontent.com,desktop.apps.googleusercontent.com",
        })
        env.start()
        self.addCleanup(env.stop)
        self.addCleanup(self.http.close)
        self.path = "/auth/google/desktop/token"
        self.code_grant = {
            "grant_type": "authorization_code",
            "client_id": "desktop.apps.googleusercontent.com",
            "code": "one-use-code",
            "code_verifier": "a" * 64,
            "redirect_uri": "http://127.0.0.1:49222/",
        }
        self.refresh_grant = {
            "grant_type": "refresh_token",
            "client_id": "desktop.apps.googleusercontent.com",
            "refresh_token": "refresh",
        }

    @patch("app.routes.desktop_oauth._exchange_with_google", new_callable=AsyncMock)
    def test_code_exchange_adds_secret_on_server_only(self, exchange):
        exchange.return_value = httpx.Response(200, json={
            "id_token": "id", "access_token": "access", "refresh_token": "refresh",
            "expires_in": 3600, "client_secret": "server-only-secret",
        })
        result = self.http.post(self.path, json=self.code_grant)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.headers["Cache-Control"], "no-store")
        self.assertEqual(result.json(), {
            "id_token": "id", "access_token": "access", "refresh_token": "refresh", "expires_in": 3600,
        })
        exchange.assert_awaited_once_with({**self.code_grant, "client_secret": "server-only-secret"})

    @patch("app.routes.desktop_oauth._exchange_with_google", new_callable=AsyncMock)
    def test_refresh_and_rejected_grant(self, exchange):
        exchange.return_value = httpx.Response(200, json={
            "id_token": "new-id", "access_token": "unused", "refresh_token": "rotated",
        })
        result = self.http.post(self.path, json=self.refresh_grant)
        self.assertEqual(result.json(), {"id_token": "new-id", "refresh_token": "rotated"})
        exchange.assert_awaited_once_with({**self.refresh_grant, "client_secret": "server-only-secret"})

        exchange.return_value = httpx.Response(400, json={
            "error": "invalid_grant", "error_description": "upstream detail",
        })
        result = self.http.post(self.path, json=self.refresh_grant)
        self.assertEqual(result.status_code, 401)
        self.assertEqual(result.json(), {"detail": {"code": "desktop_oauth_grant_rejected"}})

    @patch("app.routes.desktop_oauth._exchange_with_google", new_callable=AsyncMock)
    def test_mismatched_client_and_non_loopback_are_rejected(self, exchange):
        mismatch = self.http.post(self.path, json={**self.code_grant, "client_id": "other"})
        self.assertEqual(mismatch.status_code, 400)
        for redirect in ("https://example.com/", "http://127.0.0.1:70000/"):
            result = self.http.post(self.path, json={**self.code_grant, "redirect_uri": redirect})
            self.assertIn(result.status_code, {400, 422})
        exchange.assert_not_awaited()

    @patch("app.routes.desktop_oauth._exchange_with_google", new_callable=AsyncMock)
    def test_missing_secret_and_desktop_audience_are_reported(self, exchange):
        for name, value in (
            ("GOOGLE_DESKTOP_CLIENT_SECRET", ""),
            ("GOOGLE_OAUTH_CLIENT_IDS", "web.apps.googleusercontent.com"),
        ):
            with patch.dict(os.environ, {name: value}):
                result = self.http.post(self.path, json=self.code_grant)
            self.assertEqual(result.status_code, 503)
            self.assertEqual(result.json(), {"detail": {"code": "desktop_oauth_unconfigured"}})
        exchange.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
