"""Valida ZIP e PDF antes de entregar ao usuário."""

from __future__ import annotations

import io
import logging
import re
import stat
import zipfile
from typing import Any

logger = logging.getLogger(__name__)

MAX_ZIP_SIZE = 100 * 1024 * 1024  # 100 MB
MAX_PDF_SIZE = 50 * 1024 * 1024
MAX_ZIP_ENTRIES = 12_000

_WINDOWS_DRIVE_RE = re.compile(r"^[A-Za-z]:")
_CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")


def _is_symlink_entry(info: zipfile.ZipInfo) -> bool:
    mode = (info.external_attr >> 16) & 0xFFFF
    return stat.S_ISLNK(mode)


def validate_zip(data: bytes, *, expected_paths: list[str] | None = None) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    if not data:
        return {"ok": False, "errors": ["ZIP vazio"], "warnings": [], "entry_count": 0}

    if len(data) > MAX_ZIP_SIZE:
        errors.append(f"ZIP maior que {MAX_ZIP_SIZE // (1024*1024)} MB")

    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            bad = zf.testzip()
            if bad is not None:
                errors.append(f"Arquivo corrompido no ZIP: {bad}")

            infos = zf.infolist()
            names = [i.filename for i in infos]
            if len(names) > MAX_ZIP_ENTRIES:
                errors.append(f"Muitas entradas no ZIP ({len(names)})")

            for info in infos:
                name = info.filename
                norm = name.replace("\\", "/")
                if (
                    norm.startswith("/")
                    or _WINDOWS_DRIVE_RE.match(norm)
                    or ".." in norm.split("/")
                    or _CONTROL_CHARS_RE.search(norm)
                ):
                    errors.append(f"Path perigoso: {name!r}")
                if _is_symlink_entry(info):
                    # Links simbólicos podem apontar para fora do projeto ao extrair.
                    errors.append(f"Link simbólico não é permitido no ZIP: {name!r}")

            if expected_paths:
                have = {n.replace("\\", "/").lstrip("./") for n in names}
                for ep in expected_paths:
                    epn = ep.replace("\\", "/").lstrip("./")
                    if epn not in have and not any(h.endswith(epn) for h in have):
                        warnings.append(f"Arquivo esperado ausente: {ep}")

            return {
                "ok": len(errors) == 0,
                "errors": errors,
                "warnings": warnings,
                "entry_count": len(names),
                "sample": names[:30],
                "size": len(data),
            }
    except zipfile.BadZipFile as e:
        return {"ok": False, "errors": [f"ZIP inválido: {e}"], "warnings": [], "entry_count": 0}
    except Exception as e:
        return {"ok": False, "errors": [f"Falha ao validar ZIP: {e}"], "warnings": [], "entry_count": 0}


def validate_pdf(data: bytes, *, min_pages: int = 1) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    if not data:
        return {"ok": False, "errors": ["PDF vazio"], "warnings": [], "pages": 0}

    if len(data) > MAX_PDF_SIZE:
        errors.append(f"PDF maior que {MAX_PDF_SIZE // (1024*1024)} MB")

    if not data.startswith(b"%PDF"):
        errors.append("Assinatura PDF inválida (não começa com %PDF)")

    try:
        from pypdf import PdfReader

        reader = PdfReader(io.BytesIO(data))
        n = len(reader.pages)
        if n < min_pages:
            errors.append(f"PDF com poucas páginas ({n} < {min_pages})")

        # tenta extrair texto da 1ª página
        text_sample = ""
        if n > 0:
            try:
                text_sample = (reader.pages[0].extract_text() or "")[:200]
            except Exception:
                warnings.append("Não foi possível extrair texto da 1ª página")

        return {
            "ok": len(errors) == 0,
            "errors": errors,
            "warnings": warnings,
            "pages": n,
            "size": len(data),
            "text_sample": text_sample,
        }
    except Exception as e:
        # se pypdf falhar mas assinatura ok, ainda pode ser utilizável
        if data.startswith(b"%PDF") and not errors:
            warnings.append(f"pypdf não abriu completamente: {e}")
            return {
                "ok": True,
                "errors": [],
                "warnings": warnings,
                "pages": -1,
                "size": len(data),
            }
        return {"ok": False, "errors": [f"PDF inválido: {e}"], "warnings": warnings, "pages": 0}


def validate_path_safe(rel: str) -> bool:
    """True se o path relativo é seguro: sem traversal, sem absoluto, sem drive, sem controles."""
    if not rel or not isinstance(rel, str):
        return False
    norm = rel.replace("\\", "/").strip()
    if not norm:
        return False
    if norm.startswith("/") or norm.startswith("~") or _WINDOWS_DRIVE_RE.match(norm):
        return False
    if _CONTROL_CHARS_RE.search(norm):
        return False
    parts = norm.split("/")
    if any(p == ".." for p in parts):
        return False
    # ignora segmentos vazios/"." apenas para validar que sobra algum nome real
    if not any(p not in ("", ".") for p in parts):
        return False
    return True


def validate_source_archive(
    data: bytes,
    *,
    max_files: int = 500,
    max_file_bytes: int = 2 * 1024 * 1024,
) -> dict[str, Any]:
    """Faz validação segura e reporta a cobertura real da checagem.

    Importante: um ZIP estruturalmente válido não significa que o código compila.
    Só declaramos como sintaticamente verificados os formatos para os quais
    existe parser disponível neste backend. Outras linguagens são explicitamente
    listadas como não verificadas; código-fonte nunca é executado.
    """
    import ast
    import json
    import plistlib
    from pathlib import PurePosixPath
    import xml.etree.ElementTree as ET

    from ..code_analyzer.cleaner import is_sensitive_file

    issues: list[dict[str, Any]] = []
    skipped: list[dict[str, str]] = []
    checked: list[str] = []
    checked_languages: dict[str, int] = {}
    source_candidates = 0
    unverified_count = 0
    seen_candidates = 0

    # Extensões de código/configuração que merecem ser contadas mesmo quando
    # não há um compilador/parser da linguagem instalado no backend.
    source_suffixes = {
        ".dart", ".py", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx",
        ".java", ".kt", ".kts", ".go", ".rs", ".swift", ".cs", ".rb",
        ".php", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm",
        ".scala", ".groovy", ".lua", ".r", ".sql", ".sh", ".bash",
        ".zsh", ".ps1", ".bat", ".cmd", ".yaml", ".yml", ".json",
        ".ipynb", ".xml", ".svg", ".plist", ".toml", ".ini", ".cfg",
        ".conf", ".html", ".htm", ".css", ".scss", ".sass", ".less",
        ".gradle", ".properties", ".dockerfile",
    }
    supported = {".py", ".json", ".ipynb", ".xml", ".svg", ".plist", ".toml", ".yaml", ".yml"}

    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            candidates = [info for info in archive.infolist() if not info.is_dir()]
            for info in candidates:
                path = info.filename.replace("\\", "/")
                if is_sensitive_file(path):
                    issues.append({
                        "path": path,
                        "line": None,
                        "message": "Arquivo sensível presente no ZIP; remova credenciais antes de distribuir.",
                        "validator": "sensitive-path",
                    })
                    continue

                pure_path = PurePosixPath(path)
                ext = pure_path.suffix.lower()
                if pure_path.name.lower() == "dockerfile":
                    ext = ".dockerfile"
                is_candidate = ext in source_suffixes
                if not is_candidate:
                    continue
                source_candidates += 1
                seen_candidates += 1

                if ext not in supported:
                    unverified_count += 1
                    skipped.append({
                        "path": path,
                        "reason": f"Validação sintática não disponível para {ext or 'este formato'} neste backend",
                    })
                    continue

                if len(checked) + unverified_count >= max_files:
                    unverified_count += 1
                    skipped.append({"path": path, "reason": "limite de arquivos considerados na validação"})
                    continue
                if info.file_size > max_file_bytes:
                    unverified_count += 1
                    skipped.append({"path": path, "reason": "arquivo grande demais para validação sintática"})
                    continue

                try:
                    raw = archive.read(info)
                    if ext == ".plist":
                        plistlib.loads(raw)
                        text = ""
                    else:
                        text = raw.decode("utf-8-sig")

                    if ext == ".py":
                        ast.parse(text, filename=path)
                    elif ext in {".json", ".ipynb"}:
                        json.loads(text)
                    elif ext in {".xml", ".svg"}:
                        ET.fromstring(text)
                    elif ext == ".toml":
                        try:
                            import tomllib
                        except ImportError:
                            unverified_count += 1
                            skipped.append({"path": path, "reason": "tomllib indisponível neste Python"})
                            continue
                        tomllib.loads(text)
                    elif ext in {".yaml", ".yml"}:
                        try:
                            import yaml
                        except ImportError:
                            unverified_count += 1
                            skipped.append({"path": path, "reason": "PyYAML indisponível neste backend"})
                            continue
                        yaml.safe_load(text)

                    checked.append(path)
                    checked_languages[ext.lstrip(".")] = checked_languages.get(ext.lstrip("."), 0) + 1
                except (UnicodeDecodeError, SyntaxError, json.JSONDecodeError, ET.ParseError, ValueError, plistlib.InvalidFileException) as exc:
                    issues.append({
                        "path": path,
                        "line": getattr(exc, "lineno", None),
                        "message": str(exc).splitlines()[0][:300] or type(exc).__name__,
                        "validator": ext.lstrip("."),
                    })
                except Exception as exc:  # parser inesperado não pode derrubar a geração do artefato
                    # PyYAML expõe erros de sintaxe por YAMLError, fora das exceções
                    # da stdlib tratadas acima. Registra como problema conhecido.
                    if ext in {".yaml", ".yml"} and type(exc).__name__.endswith("YAMLError"):
                        issues.append({
                            "path": path,
                            "line": getattr(getattr(exc, "problem_mark", None), "line", None),
                            "message": str(exc).splitlines()[0][:300],
                            "validator": "yaml",
                        })
                    else:
                        unverified_count += 1
                        skipped.append({"path": path, "reason": f"falha no validador: {type(exc).__name__}"})
    except (zipfile.BadZipFile, OSError) as exc:
        return {
            "ok": False,
            "status": "invalid_archive",
            "checked_count": 0,
            "checked_paths": [],
            "issues": [{"path": "", "line": None, "message": f"ZIP inválido: {exc}"}],
            "issue_count": 1,
            "skipped": [],
            "skipped_count": 0,
            "source_candidate_count": 0,
            "unverified_count": 0,
            "syntax_check_complete": False,
            "note": "O arquivo não pôde ser lido como ZIP.",
        }

    if issues:
        status = "issues_found"
        label = "Foram encontrados problemas; veja a lista de ocorrências."
    elif checked and unverified_count == 0:
        status = "passed"
        label = "Os arquivos suportados passaram nos parsers sintáticos disponíveis."
    elif checked:
        status = "partial"
        label = "Validação parcial: alguns arquivos não puderam ser verificados."
    elif source_candidates:
        status = "not_checked"
        label = "Nenhum arquivo-fonte pôde ser validado sintaticamente neste backend."
    else:
        status = "no_source_files"
        label = "Nenhum arquivo-fonte reconhecido para validação sintática."

    return {
        # `ok` mantém o significado anterior para consumidores existentes: nenhum
        # problema conhecido. Use `status`/`syntax_check_complete` para cobertura.
        "ok": not issues,
        "status": status,
        "status_label": label,
        "checked_count": len(checked),
        "checked_paths": checked[:200],
        "checked_languages": checked_languages,
        "issues": issues[:200],
        "issue_count": len(issues),
        "skipped": skipped[:200],
        "skipped_count": len(skipped),
        "source_candidate_count": source_candidates,
        "unverified_count": unverified_count,
        "syntax_check_complete": bool(checked) and unverified_count == 0 and not issues,
        "note": (
            "A validade estrutural do ZIP e a validação sintática são verificações diferentes. "
            "Arquivos em linguagens sem parser disponível estão marcados como não verificados. "
            "Esta checagem não substitui compilação, análise estática da linguagem, testes ou revisão humana."
        ),
    }

