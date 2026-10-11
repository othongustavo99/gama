"""Text extraction for DOCX files without extracting their embedded assets."""

from __future__ import annotations

import io
import re
import zipfile
from typing import Any
from xml.etree import ElementTree

_WORD_NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
_MAX_XML_BYTES = 30 * 1024 * 1024
_MAX_SEGMENT_CHARS = 12_000


def extract_docx_segments(docx_bytes: bytes) -> list[dict[str, Any]]:
    """Read paragraphs in document order and split them into searchable chunks."""
    try:
        with zipfile.ZipFile(io.BytesIO(docx_bytes)) as archive:
            try:
                info = archive.getinfo("word/document.xml")
            except KeyError as exc:
                raise ValueError("DOCX inválido: conteúdo principal não encontrado") from exc
            if info.file_size > _MAX_XML_BYTES:
                raise ValueError("Documento DOCX muito grande para leitura segura")
            if info.compress_size and info.file_size / info.compress_size > 200:
                raise ValueError("Documento DOCX recusado por compressão suspeita")
            xml = archive.read(info)
    except zipfile.BadZipFile as exc:
        raise ValueError("O arquivo enviado não é um DOCX válido") from exc

    if b"<!DOCTYPE" in xml.upper() or b"<!ENTITY" in xml.upper():
        raise ValueError("Documento DOCX contém declarações XML não permitidas")

    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError as exc:
        raise ValueError("Documento DOCX corrompido") from exc

    paragraphs: list[str] = []
    for paragraph in root.iter(f"{_WORD_NS}p"):
        pieces: list[str] = []
        for node in paragraph.iter():
            if node.tag == f"{_WORD_NS}t" and node.text:
                pieces.append(node.text)
            elif node.tag == f"{_WORD_NS}tab":
                pieces.append("\t")
            elif node.tag == f"{_WORD_NS}br":
                pieces.append("\n")
        text = "".join(pieces).strip()
        if text:
            paragraphs.append(text)

    if not paragraphs:
        raise ValueError("DOCX sem texto extraível")

    # Keep paragraph boundaries and split only between paragraphs where possible.
    segments: list[str] = []
    current: list[str] = []
    current_size = 0
    for paragraph in paragraphs:
        pieces = [paragraph[i : i + _MAX_SEGMENT_CHARS] for i in range(0, len(paragraph), _MAX_SEGMENT_CHARS)]
        for piece in pieces:
            if current and current_size + len(piece) + 2 > _MAX_SEGMENT_CHARS:
                segments.append("\n\n".join(current))
                current, current_size = [], 0
            current.append(piece)
            current_size += len(piece) + 2
    if current:
        segments.append("\n\n".join(current))

    result = []
    for index, text in enumerate(segments, start=1):
        has_code = bool(re.search(
            r"(?:\bdef\s|\bclass\s|\bfunction\s|\bimport\s|\bpackage\s|\bpublic\s|\bprivate\s|=>|:=|#include|console\.|print\()",
            text,
        ))
        result.append({
            "page": index,
            "path": f"segment_{index}",
            "text": text,
            "size": len(text),
            "has_code": has_code,
            "lang": "code" if has_code else "text",
            "important": has_code,
        })
    return result


def segments_to_map(segments: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "file_count": len(segments),
        "languages": {"DOCX": len(segments)},
        "frameworks": ["DOCX/Documentação"],
        "files": [
            {
                "path": item["path"],
                "size": item["size"],
                "ext": ".docx-segment",
                "lang": item.get("lang", "text"),
                "important": item.get("important", False),
            }
            for item in segments
        ],
        "top_dirs": [],
    }
