"""Diagnóstico do armazenamento persistente do backend."""

from __future__ import annotations

import os
import tempfile
from functools import lru_cache
from pathlib import Path


@lru_cache(maxsize=1)
def inspect_data_storage() -> dict[str, object]:
    """Verifica se DATA_DIR corresponde ao volume Railway e aceita escrita.

    O resultado não expõe o caminho físico na resposta pública de health.
    Fora do Railway, persistência é reportada como não verificada.
    """
    data_dir = Path(os.getenv("DATA_DIR", "/data")).expanduser()
    volume_mount = os.getenv("RAILWAY_VOLUME_MOUNT_PATH", "").strip()
    is_railway = bool(os.getenv("RAILWAY_PROJECT_ID"))
    volume_attached = bool(volume_mount)

    try:
        data_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix=".gama-storage-check-", dir=data_dir):
            pass
        writable = True
    except OSError:
        writable = False

    matches_volume = False
    if volume_attached:
        try:
            matches_volume = data_dir.resolve() == Path(volume_mount).expanduser().resolve()
        except OSError:
            matches_volume = False

    if volume_attached and matches_volume and writable:
        status = "persistent"
    elif volume_attached and not matches_volume:
        status = "path_mismatch"
    elif not writable:
        status = "not_writable"
    elif is_railway:
        status = "volume_not_attached"
    else:
        status = "unverified_local"

    return {
        "status": status,
        "persistent": status == "persistent",
        "volume_attached": volume_attached,
        "data_dir_matches_volume": matches_volume,
        "writable": writable,
    }
