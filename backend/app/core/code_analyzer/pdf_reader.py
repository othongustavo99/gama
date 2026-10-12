"""PDF reader with native text extraction and optional Tesseract OCR."""

from __future__ import annotations

import io
import logging
import os
import re
from typing import Any

logger = logging.getLogger(__name__)

MAX_CHARS_PER_PAGE = 50_000
MAX_PAGES = 200
MAX_OCR_PAGES = 80
MIN_NATIVE_TEXT_CHARS = 35
OCR_DPI = 160

_CODE_HINT = re.compile(
    r"(?:def |class |function |import |package |void |public |private |fn |func |"
    r"\{\s*$|;\s*$|=>|:=|#include|console\.|print\(|"
    r"@override|Widget |Future<|async |await |return |"
    r"from \w+ import|require\(|module\.exports|"
    r"public class |interface |enum |struct |type )",
    re.M,
)


def _open_ocr_document(pdf_bytes: bytes) -> tuple[Any | None, str]:
    """Open PyMuPDF lazily so text-only PDFs work without OCR system packages."""
    try:
        import fitz
    except ImportError:
        return None, "pymupdf_unavailable"

    try:
        document = fitz.open(stream=pdf_bytes, filetype="pdf")
        if not len(document) or not hasattr(document[0], "get_textpage_ocr"):
            document.close()
            return None, "ocr_unsupported"
        return document, "ready"
    except Exception as exc:
        logger.warning("Não foi possível inicializar OCR do PDF: %s", exc)
        return None, "ocr_unavailable"


def _ocr_page(document: Any, page_index: int, language: str) -> str:
    page = document.load_page(page_index)
    text_page = page.get_textpage_ocr(language=language, dpi=OCR_DPI, full=True)
    return (page.get_text("text", textpage=text_page) or "").strip()


def _make_page(page_number: int, text: str, method: str) -> dict[str, Any]:
    if len(text) > MAX_CHARS_PER_PAGE:
        text = text[:MAX_CHARS_PER_PAGE] + " …[página limitada]"
    has_code = bool(_CODE_HINT.search(text)) or (
        text.count("\n") > 8
        and any(token in text for token in ("{", ";", "def ", "class ", "function ", "import "))
    )
    return {
        "page": page_number,
        "path": f"page_{page_number}",
        "text": text,
        "size": len(text),
        "has_code": has_code,
        "lang": "code" if has_code else "text",
        "important": has_code,
        "extraction_method": method,
    }


def extract_pages_detailed(
    pdf_bytes: bytes,
    *,
    max_pages: int = MAX_PAGES,
    enable_ocr: bool = True,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Return extracted pages and explicit OCR/coverage metadata.

    OCR is attempted only on pages with little or no selectable text, and is
    bounded to ``MAX_OCR_PAGES`` to keep uploads responsive and predictable.
    PyMuPDF uses the system Tesseract installation; absence of OCR never breaks
    extraction of pages that already contain selectable text.
    """
    try:
        from pypdf import PdfReader
    except ImportError as exc:
        raise RuntimeError("pypdf não instalado") from exc

    try:
        reader = PdfReader(io.BytesIO(pdf_bytes))
    except Exception as exc:
        raise ValueError(f"PDF inválido ou corrompido: {exc}") from exc

    if getattr(reader, "is_encrypted", False):
        try:
            reader.decrypt("")
        except Exception as exc:
            raise ValueError("PDF criptografado; não é possível extrair texto") from exc

    total_pages = len(reader.pages)
    page_limit = max(1, min(int(max_pages), MAX_PAGES))
    process_count = min(total_pages, page_limit)
    stats: dict[str, Any] = {
        "total_pages": total_pages,
        "processed_pages": process_count,
        "page_limit_reached": total_pages > process_count,
        "ocr_enabled": bool(enable_ocr),
        "ocr_pages": 0,
        "scanned_pages": 0,
        "ocr_skipped_pages": 0,
        "ocr_failed_pages": 0,
        "unreadable_pages": 0,
        "ocr_status": "not_needed",
    }

    ocr_document = None
    ocr_state = "disabled"
    if enable_ocr:
        ocr_document, ocr_state = _open_ocr_document(pdf_bytes)
    stats["ocr_status"] = ocr_state
    language = (os.getenv("GAMA_OCR_LANG") or "por+eng").strip() or "por+eng"

    pages: list[dict[str, Any]] = []
    try:
        for index in range(process_count):
            try:
                text = (reader.pages[index].extract_text() or "").strip()
            except Exception as exc:
                logger.warning("Falha ao extrair texto da página %s: %s", index + 1, exc)
                text = ""

            method = "native"
            if len(text) < MIN_NATIVE_TEXT_CHARS:
                stats["scanned_pages"] += 1
                if ocr_document is None:
                    if enable_ocr:
                        stats["ocr_skipped_pages"] += 1
                elif stats["ocr_pages"] + stats["ocr_failed_pages"] < MAX_OCR_PAGES:
                    try:
                        ocr_text = _ocr_page(ocr_document, index, language)
                        if len(ocr_text) > len(text):
                            text = ocr_text
                            method = "ocr"
                            stats["ocr_pages"] += 1
                        else:
                            stats["ocr_failed_pages"] += 1
                    except Exception as exc:
                        stats["ocr_failed_pages"] += 1
                        stats["ocr_status"] = "partial_failure"
                        logger.warning("OCR falhou na página %s: %s", index + 1, exc)
                elif enable_ocr:
                    stats["ocr_skipped_pages"] += 1

            if not text:
                stats["unreadable_pages"] += 1
                continue
            pages.append(_make_page(index + 1, text, method))
    finally:
        if ocr_document is not None:
            try:
                ocr_document.close()
            except Exception:
                pass

    if not stats["scanned_pages"]:
        stats["ocr_status"] = "not_needed"
    elif stats["ocr_failed_pages"] and stats["ocr_pages"]:
        stats["ocr_status"] = "partial"
    elif stats["ocr_failed_pages"]:
        stats["ocr_status"] = "failed"
    elif enable_ocr and ocr_state != "ready":
        stats["ocr_status"] = ocr_state
    elif stats["ocr_skipped_pages"]:
        stats["ocr_status"] = "partial"
    elif stats["ocr_pages"]:
        stats["ocr_status"] = "completed"
    else:
        stats["ocr_status"] = ocr_state
    return pages, stats


def extract_pages(pdf_bytes: bytes, *, max_pages: int = MAX_PAGES) -> list[dict[str, Any]]:
    """Backward-compatible convenience wrapper returning only page records."""
    pages, _ = extract_pages_detailed(pdf_bytes, max_pages=max_pages)
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
    for page in pages:
        score = score_file(page["path"], page["text"], terms, bool(page.get("important")))
        if score <= 0 and not page.get("important"):
            continue
        scored.append(
            {
                "path": page["path"],
                "score": score,
                "important": page.get("important"),
                "text": page["text"],
                "preview": page["text"][:400],
                "page": page["page"],
            }
        )
    scored.sort(key=lambda item: -item["score"])
    return scored[:top_k]
