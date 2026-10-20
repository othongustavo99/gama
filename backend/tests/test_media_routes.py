from __future__ import annotations

import asyncio
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest
from fastapi import HTTPException
from fastapi.responses import FileResponse

from app.core import media_links
from app.routes import media as media_routes


def test_reference_media_uses_a_signed_owner_scoped_url(tmp_path: Path, monkeypatch):
    media_file = tmp_path / "reference.png"
    media_file.write_bytes(b"fake-png-data")

    monkeypatch.setattr(media_links.settings, "GAMA_API_KEY", "k" * 40, raising=False)
    monkeypatch.setattr(media_links.settings, "OPENROUTER_API_KEY", "", raising=False)
    monkeypatch.setattr(media_links.settings, "APP_URL", "https://api.example.test", raising=False)

    def fake_load_artifact(artifact_id: str, user_id: str | None = None, **_kwargs):
        if artifact_id != "0123456789abcdef" or user_id != "user_1":
            return None
        return {
            "kind": "image",
            "filename": media_file.name,
            "path": str(media_file),
            "mime": "image/png",
            "user_id": user_id,
        }

    monkeypatch.setattr(media_routes, "load_artifact", fake_load_artifact)

    async def run_case():
        result = await media_routes.create_reference_url(
            "0123456789abcdef", user_id="user_1"
        )
        parsed = urlparse(result["url"])
        query = parse_qs(parsed.query)
        assert parsed.path == "/media/reference/0123456789abcdef"
        assert query["owner"] == ["user_1"]
        assert result["expires_in"] == 1800

        served = await media_routes.serve_reference_media(
            "0123456789abcdef",
            expires=int(query["expires"][0]),
            signature=query["signature"][0],
            owner="user_1",
        )
        assert isinstance(served, FileResponse)
        assert Path(served.path) == media_file.resolve()

        with pytest.raises(HTTPException) as denied:
            await media_routes.serve_reference_media(
                "0123456789abcdef",
                expires=int(query["expires"][0]),
                signature=query["signature"][0],
                owner="user_2",
            )
        assert denied.value.status_code == 403

    asyncio.run(run_case())
