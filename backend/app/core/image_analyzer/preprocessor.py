"""Pré-processamento seguro de imagens para o Image Analyzer.

A imagem original nunca é alterada. O pipeline cria uma cópia otimizada
somente para a chamada visual ao modelo.
"""

from __future__ import annotations

import base64
import io
import logging
from dataclasses import dataclass
from typing import Iterable

from PIL import Image, ImageOps

logger = logging.getLogger(__name__)

MAX_INPUT_BYTES = 12 * 1024 * 1024
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
DEFAULT_MAX_SIDE = 1600
TEXT_MAX_SIDE = 2200


@dataclass
class PreparedImage:
    name: str
    mime: str
    data: str
    width: int
    height: int
    original_bytes: int
    output_bytes: int
    mode: str


def _looks_text_heavy(query: str) -> bool:
    q = (query or "").lower()
    terms = (
        "texto", "ler", "leia", "código", "codigo", "erro", "stack trace",
        "terminal", "log", "documento", "pdf", "tabela", "planilha",
        "screenshot", "captura", "android studio", "visual studio", "ide",
        "programação", "programacao", "interface", "tela", "site", "web",
        "linha", "mensagem", "número", "numero", "design", "layout",
    )
    return any(t in q for t in terms)


def prepare_image(raw: bytes, *, name: str, query: str) -> PreparedImage:
    if not raw:
        raise ValueError(f"Imagem vazia: {name}")
    if len(raw) > MAX_INPUT_BYTES:
        raise ValueError(f"Imagem muito grande para análise segura: {name}")

    with Image.open(io.BytesIO(raw)) as source:
        source = ImageOps.exif_transpose(source)
        width, height = source.size
        if width <= 0 or height <= 0:
            raise ValueError(f"Dimensões inválidas: {name}")

        text_heavy = _looks_text_heavy(query)
        max_side = TEXT_MAX_SIDE if text_heavy else DEFAULT_MAX_SIDE

        # Preserva a resolução original quando ela já é adequada.
        image = source.copy()
        scale = min(1.0, max_side / max(width, height))
        if scale < 1.0:
            image = image.resize(
                (max(1, round(width * scale)), max(1, round(height * scale))),
                Image.Resampling.LANCZOS,
            )

        # JPEG é muito mais econômico para fotos e screenshots sem transparência.
        # Para imagens com alpha, achata sobre branco para evitar perda visual.
        has_alpha = "A" in image.getbands()
        if image.mode not in ("RGB", "RGBA"):
            image = image.convert("RGBA" if has_alpha else "RGB")
        if image.mode == "RGBA":
            bg = Image.new("RGB", image.size, "white")
            bg.paste(image, mask=image.getchannel("A"))
            image = bg
        elif image.mode != "RGB":
            image = image.convert("RGB")

        quality = 90 if text_heavy else 84
        encoded = b""
        for q in range(quality, 69, -4):
            buf = io.BytesIO()
            image.save(
                buf,
                format="JPEG",
                quality=q,
                optimize=True,
                progressive=True,
            )
            candidate = buf.getvalue()
            encoded = candidate
            if len(candidate) <= MAX_OUTPUT_BYTES:
                break

        if len(encoded) > MAX_OUTPUT_BYTES:
            raise ValueError(f"Não foi possível otimizar a imagem: {name}")

        out_w, out_h = image.size
        return PreparedImage(
            name=name,
            mime="image/jpeg",
            data=base64.b64encode(encoded).decode("ascii"),
            width=out_w,
            height=out_h,
            original_bytes=len(raw),
            output_bytes=len(encoded),
            mode="text-priority" if text_heavy else "visual-balanced",
        )


def prepare_many(images: Iterable[dict], query: str) -> list[PreparedImage]:
    result: list[PreparedImage] = []
    for image in list(images)[:3]:
        data = (image.get("data") or "").strip()
        if not data:
            continue
        raw = b""
        try:
            raw = base64.b64decode(data, validate=False)
            result.append(
                prepare_image(
                    raw,
                    name=str(image.get("name") or "imagem"),
                    query=query,
                )
            )
        except Exception as exc:
            logger.warning("image preprocessing failed for %s: %s", image.get("name"), exc)
            # A falha no otimizador não quebra o chat inteiro; a imagem original
            # continua disponível como fallback.
            result.append(
                PreparedImage(
                    name=str(image.get("name") or "imagem"),
                    mime=str(image.get("mime") or "image/jpeg"),
                    data=data,
                    width=0,
                    height=0,
                    original_bytes=len(raw),
                    output_bytes=len(raw),
                    mode="original-fallback",
                )
            )
    return result
