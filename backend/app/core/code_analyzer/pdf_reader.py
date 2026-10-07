"""PDF Code Reader — extrai páginas, detecta blocos de código, indexa por página."""

from __future__ import annotations

import io
import logging
import re
from typing import Any

logger = logging.getLogger(__name__)

_CODE_HINT = re.compile(
    r"(?:def |class |function |import |package |void |public |private |fn |func |"
    r"\{\s*$|;\s*$|=>|:=|#include|console\.|print\()",
    re.M,
)


def extract_pages(pdf_bytes: bytes, *, max_pages: int = 200) -> list[dict[str, Any]]:
    try:
        from pypdf import PdfReader
    except ImportError as e:
        raise RuntimeError("pypdf não instalado") from e

    reader = PdfReader(io.BytesIO(pdf_bytes))
    pages: list[dict[str, Any]] = []
    for i, page in enumerate(reader.pages[:max_pages]):
        try:
            text = page.extract_text() or ""
        except Exception:
            text = ""
        text = text.strip()
        if not text:
            continue
        has_code = bool(_CODE_HINT.search(text)) or text.count("\n") > 8 and (
            "{" in text or ";" in text or "def " in text or "class " in text
        )
        pages.append(
            {
                "page": i + 1,
                "path": f"page_{i + 1}",
                "text": text,
                "size": len(text),
                "has_code": has_code,
                "lang": "code" if has_code else "text",
                "important": has_code,
            }
        )
    return pages


def pages_to_map(pages: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "file_count": len(pages),
        "languages": {"PDF": len(pages)},
        "frameworks": ["PDF/Documentação"],
        "files": [
            {
                "path": p["path"],
                "size": p["size"],
                "ext": ".pdf-page",
                "lang": p.get("lang", "text"),
                "important": p.get("important", False),
            }
            for p in pages
        ],
        "top_dirs": [],
    }


def search_pages(
    pages: list[dict[str, Any]], query: str, *, top_k: int = 12
) -> list[dict[str, Any]]:
    from .code_search import expand_query, score_file

    terms = expand_query(query)
    scored = []
    for p in pages:
        sc = score_file(p["path"], p["text"], terms, bool(p.get("important")))
        if sc <= 0 and not p.get("important"):
            continue
        scored.append(
            {
                "path": p["path"],
                "score": sc,
                "important": p.get("important"),
                "text": p["text"],
                "preview": p["text"][:400],
                "page": p["page"],
            }
        )
    scored.sort(key=lambda x: -x["score"])
    return scored[:top_k]
