"""Orquestra Code Analyzer: ingestão + busca + deps + relevância + contexto.

Níveis: quick | targeted | deep
Fontes: zip | github | pdf | direct
"""

from __future__ import annotations

import asyncio
import logging
import re
from pathlib import Path
from typing import Any, Optional

import httpx

from .code_search import search_files, extract_mentioned_filenames, find_matching_paths
from .cleaner import is_sensitive_file
from .context_builder import build_context
from .dependency_resolver import resolve_dependencies
from .document_reader import extract_docx_segments, segments_to_map
from .extractor import safe_extract
from .github_reader import (
    MAX_TEXT_FILE_BYTES,
    fetch_file_content,
    fetch_file_with_path_guess,
    get_tree_full,
    has_github_token,
)
from .index_store import (
    cleanup_old,
    find_github_cache,
    load_meta,
    new_project_id,
    save_meta,
    workspace,
)
from .mapper import build_symbol_index, walk_project
from .pdf_reader import extract_pages_detailed, pages_to_map, search_pages
from .relevance import rank_for_query, suggest_followup_paths
from .source_detector import detect_level, parse_github_url

logger = logging.getLogger(__name__)



def _stem_close(path: str, mention: str) -> bool:
    """Match flexível de basename (context.py ↔ contexto)."""
    from pathlib import Path as _P
    a = _P(path).stem.lower()
    b = _P(mention).stem.lower()
    if a == b:
        return True
    if len(a) >= 4 and len(b) >= 4 and (a in b or b in a):
        return True
    aliases = {
        "contexto": "context", "context": "contexto",
        "memoria": "memory", "memory": "memoria",
        "configuracao": "config", "config": "configuracao",
    }
    return aliases.get(a) == b or aliases.get(b) == a



def _wants_full_file(query: str) -> bool:
    q = (query or "").lower()
    keys = (
        "conteúdo completo", "conteudo completo", "texto integral", "texto completo",
        "texto literal", "arquivo completo", "linha por linha", "na íntegra", "na integra",
        "completo e literal", "o que tem dentro", "o que está dentro", "o que esta dentro",
        "exatamente o que", "me diga exatamente", "full content",
        "entire file", "whole file", "dentro de main", "dentro do arquivo",
    )
    if any(k in q for k in keys):
        return True
    # menção a arquivo específico (ex.: main.dart) → carregar integral
    if re.search(
        r"\b[\w./\-]+\.(?:dart|py|js|ts|tsx|jsx|java|kt|go|rs|swift|cs)\b",
        q,
    ):
        return True
    return False


def _scan_root_for(project_id: str, meta: dict[str, Any]) -> Path:
    """Resolve the indexed scan root without guessing after lazy downloads.

    ZIP ingestion records its detected top-level project directory in
    ``scan_root``. GitHub projects, in contrast, keep repository-relative paths
    and populate their workspace file-by-file; treating a sole downloaded
    directory (for example ``lib/``) as a new root duplicates the prefix and
    makes cached source files appear missing.
    """
    root = workspace(project_id)
    rel = meta.get("scan_root") or "."
    if rel in (".", "", None):
        source = meta.get("source") or {}
        if source.get("type") == "github" or meta.get("github_lazy"):
            return root
        children = [p for p in root.iterdir()] if root.exists() else []
        if len(children) == 1 and children[0].is_dir():
            return children[0]
        return root
    return root / rel


def _review_plan_preview(meta: dict[str, Any]) -> dict[str, Any]:
    """Prévia de cobertura, sem executar ou cobrar chamadas ao modelo."""
    from .deep_review import plan_review_batches

    plan = plan_review_batches(meta)
    return {
        "eligible_files": plan["eligible_files"],
        "planned_files": len(plan["selected_paths"]),
        "omitted_files": len(plan["omitted_paths"]),
        "planned_passes": len(plan["batches"]),
        "note": "Planejamento, não evidência de que estes arquivos foram lidos ou revisados.",
    }


# ─── Ingest ───────────────────────────────────────────────────────────────


def ingest_zip(
    zip_bytes: bytes,
    *,
    name: str = "project.zip",
    user_id: str = "default",
) -> dict[str, Any]:
    cleanup_old()
    project_id = new_project_id()
    root = workspace(project_id)
    if root.exists():
        import shutil

        shutil.rmtree(root, ignore_errors=True)
    n = safe_extract(zip_bytes, root)
    if n == 0:
        raise ValueError("ZIP vazio ou sem arquivos extraíveis")

    children = [p for p in root.iterdir()]
    scan_root = root
    if len(children) == 1 and children[0].is_dir():
        scan_root = children[0]

    map_data = walk_project(scan_root)
    symbol_index = build_symbol_index(scan_root, map_data["files"])

    meta = {
        "name": name,
        "user_id": user_id,
        "source": {"type": "zip", "name": name},
        "extracted_files": n,
        "scan_root": str(scan_root.relative_to(workspace(project_id)))
        if scan_root != root
        else ".",
        "map": map_data,
        "symbols": symbol_index,
    }
    save_meta(project_id, meta)

    return {
        "project_id": project_id,
        "name": name,
        "source": "zip",
        "file_count": map_data["file_count"],
        "frameworks": map_data["frameworks"],
        "languages": map_data["languages"],
        "sample_paths": [f["path"] for f in map_data["files"][:25]],
        "review_plan": _review_plan_preview(meta),
    }


async def ingest_github(
    owner: str,
    repo: str,
    *,
    branch: str = "main",
    path_prefix: str = "",
    user_id: str = "default",
) -> dict[str, Any]:
    """Indexa a árvore GitHub e baixa blobs relevantes somente sob demanda.

    Se a API retornar 403 (rate limit), cria projeto em modo *raw-only*:
    arquivos são buscados via raw.githubusercontent.com / jsDelivr (sem rate limit).
    """
    # These values come from a URL or directly from the API request. Validate
    # them before constructing GitHub URLs or filesystem cache paths.
    slug_pattern = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
    if (
        not slug_pattern.fullmatch(owner or "")
        or not slug_pattern.fullmatch(repo or "")
        or owner in {".", ".."}
        or repo in {".", ".."}
    ):
        raise ValueError("Owner ou nome do repositório GitHub inválido")

    cleanup_old()
    path_prefix = (path_prefix or "").replace("\\", "/").strip(" /")
    if any(part in {".", ".."} for part in path_prefix.split("/") if part):
        raise ValueError("Caminho GitHub inválido")
    tree_sha = "raw"
    commit_sha = ""
    entries: list[dict[str, Any]] = []
    raw_only = False
    tree_partial = False

    try:
        tree_sha, entries, branch, tree_partial, commit_sha = await get_tree_full(owner, repo, branch)
        if path_prefix:
            entries = [
                item for item in entries
                if item["path"] == path_prefix or item["path"].startswith(path_prefix + "/")
            ]
            if not entries:
                raise ValueError(f"Caminho '{path_prefix}' não encontrado em {owner}/{repo}@{branch}")
        cached = find_github_cache(owner, repo, branch, tree_sha, user_id=user_id) if not path_prefix else None
        if cached:
            summary = get_project_summary(cached)
            if summary:
                return {**summary, "cached": True, "source": "github"}
    except Exception as e:
        if isinstance(e, ValueError):
            raise
        status = getattr(getattr(e, "response", None), "status_code", None)
        if status not in {403, 429} and not isinstance(
            e, (httpx.TimeoutException, httpx.TransportError)
        ):
            raise
        logger.warning("github get_tree failed (%s) — modo raw-only", e)
        raw_only = True
        # sem árvore: ainda assim criamos projeto para fetch sob demanda
        entries = []

    project_id = new_project_id()
    # materializa só metadados (sem conteúdo ainda)
    # filtra como cleaner faria
    from .cleaner import should_skip_dir, should_skip_file
    from pathlib import PurePosixPath

    files: list[dict[str, Any]] = []
    oversized_files: list[str] = []
    lang_counter: dict[str, int] = {}
    from .mapper import LANG_BY_EXT
    from .cleaner import is_important

    for e in entries:
        path = e["path"]
        parts = PurePosixPath(path).parts
        if any(should_skip_dir(p) for p in parts[:-1]):
            continue
        # fake path for suffix checks
        fake = Path(path)
        if should_skip_file(fake):
            continue
        if e.get("size", 0) > MAX_TEXT_FILE_BYTES:
            oversized_files.append(path)
            continue
        ext = fake.suffix.lower()
        lang = LANG_BY_EXT.get(ext, "other")
        if lang != "other":
            lang_counter[lang] = lang_counter.get(lang, 0) + 1
        files.append(
            {
                "path": path,
                "size": e.get("size") or 0,
                "ext": ext,
                "lang": lang,
                "important": is_important(fake),
                "sha": e.get("sha"),
            }
        )

    files.sort(key=lambda f: (not f["important"], f["path"]))
    from .mapper import detect_framework

    map_data = {
        "file_count": len(files),
        "languages": dict(sorted(lang_counter.items(), key=lambda x: -x[1])[:12]),
        "frameworks": detect_framework(Path("."), [f["path"] for f in files]),
        "files": files,
        "top_dirs": sorted({str(PurePosixPath(f["path"]).parts[0]) for f in files if PurePosixPath(f["path"]).parts})[:40],
    }

    meta = {
        "name": f"{owner}/{repo}",
        "user_id": user_id,
        "source": {
            "type": "github",
            "commit_sha": commit_sha or None,
            "owner": owner,
            "repo": repo,
            "branch": branch,
            "path_prefix": path_prefix,
            "tree_sha": tree_sha,
            "key": f"{owner}/{repo}@{branch}".lower(),
            "raw_only": raw_only,
            "oversized_files": oversized_files[:200],
            "oversized_file_count": len(oversized_files),
        },
        "scan_root": ".",
        "map": map_data,
        "symbols": {},  # preenchido sob demanda / partial
        "github_lazy": True,
        "github_raw_only": raw_only,
        "github_tree_partial": tree_partial,
    }
    save_meta(project_id, meta)
    # workspace vazio — conteúdo vem da API
    workspace(project_id).mkdir(parents=True, exist_ok=True)

    return {
        "project_id": project_id,
        "name": f"{owner}/{repo}",
        "source": "github",
        "branch": branch,
        "path_prefix": path_prefix,
        "tree_partial": tree_partial,
        "oversized_file_count": len(oversized_files),
        "file_count": map_data["file_count"],
        "frameworks": map_data["frameworks"],
        "languages": map_data["languages"],
        "sample_paths": [f["path"] for f in files[:25]],
        "review_plan": _review_plan_preview(meta),
        "cached": False,
    }


def ingest_pdf(
    pdf_bytes: bytes,
    *,
    name: str = "document.pdf",
    user_id: str = "default",
) -> dict[str, Any]:
    cleanup_old()
    project_id = new_project_id()
    pages, extraction = extract_pages_detailed(pdf_bytes)
    if not pages:
        if extraction.get("scanned_pages"):
            raise ValueError(
                "PDF sem texto selecionável. O OCR não estava disponível ou não conseguiu "
                "reconhecer texto; instale PyMuPDF e Tesseract com os idiomas configurados."
            )
        raise ValueError("PDF sem texto extraível")

    map_data = pages_to_map(pages)
    map_data["pdf_extraction"] = extraction
    # guarda páginas no meta (texto já extraído)
    meta = {
        "name": name,
        "user_id": user_id,
        "source": {"type": "pdf", "name": name},
        "scan_root": ".",
        "map": map_data,
        "symbols": {},
        "pdf_pages": pages,
        "pdf_extraction": extraction,
    }
    save_meta(project_id, meta)
    workspace(project_id).mkdir(parents=True, exist_ok=True)

    return {
        "project_id": project_id,
        "name": name,
        "source": "pdf",
        "file_count": len(pages),
        "frameworks": ["PDF/Documentação"],
        "languages": {"PDF": len(pages)},
        "sample_paths": [p["path"] for p in pages[:15]],
        "ocr_pages": extraction.get("ocr_pages", 0),
        "scanned_pages": extraction.get("scanned_pages", 0),
        "ocr_skipped_pages": extraction.get("ocr_skipped_pages", 0),
        "page_limit_reached": extraction.get("page_limit_reached", False),
    }


def ingest_docx(
    docx_bytes: bytes,
    *,
    name: str = "document.docx",
    user_id: str = "default",
) -> dict[str, Any]:
    """Index a Word document as searchable text segments."""
    cleanup_old()
    project_id = new_project_id()
    segments = extract_docx_segments(docx_bytes)
    map_data = segments_to_map(segments)
    save_meta(project_id, {
        "name": name,
        "user_id": user_id,
        "source": {"type": "docx", "name": name},
        "scan_root": ".",
        "map": map_data,
        "symbols": {},
        "document_pages": segments,
    })
    workspace(project_id).mkdir(parents=True, exist_ok=True)
    return {
        "project_id": project_id,
        "name": name,
        "source": "docx",
        "file_count": len(segments),
        "frameworks": map_data["frameworks"],
        "languages": map_data["languages"],
        "sample_paths": [item["path"] for item in segments[:15]],
    }


def ingest_direct_code(
    code: str,
    *,
    name: str = "snippet",
    user_id: str = "default",
) -> dict[str, Any]:
    cleanup_old()
    project_id = new_project_id()
    root = workspace(project_id)
    root.mkdir(parents=True, exist_ok=True)
    # detect extension heuristically
    ext = ".txt"
    if "package " in code or "Widget" in code or "pubspec" in code:
        ext = ".dart"
    elif "def " in code or "import " in code and "from " in code:
        ext = ".py"
    elif "function " in code or "const " in code or "=>" in code:
        ext = ".ts"
    path = root / f"snippet{ext}"
    path.write_text(code, encoding="utf-8")

    map_data = walk_project(root)
    symbol_index = build_symbol_index(root, map_data["files"])
    meta = {
        "name": name,
        "user_id": user_id,
        "source": {"type": "direct"},
        "scan_root": ".",
        "map": map_data,
        "symbols": symbol_index,
    }
    save_meta(project_id, meta)
    return {
        "project_id": project_id,
        "name": name,
        "source": "direct",
        "file_count": map_data["file_count"],
        "frameworks": map_data["frameworks"],
        "languages": map_data["languages"],
        "sample_paths": [f["path"] for f in map_data["files"][:10]],
    }


def get_project_summary(project_id: str) -> Optional[dict[str, Any]]:
    meta = load_meta(project_id)
    if not meta:
        return None
    m = meta.get("map") or {}
    src = meta.get("source") or {}
    return {
        "project_id": project_id,
        "name": meta.get("name"),
        "source": src.get("type", "zip"),
        "file_count": m.get("file_count"),
        "frameworks": m.get("frameworks"),
        "languages": m.get("languages"),
        "sample_paths": [f["path"] for f in (m.get("files") or [])[:30]],
        "github_raw_only": bool(src.get("raw_only")),
        "github_tree_partial": bool(meta.get("github_tree_partial")),
    }


# ─── Query context ────────────────────────────────────────────────────────


async def _load_github_texts(
    meta: dict[str, Any],
    paths: list[str],
) -> dict[str, str]:
    """Baixa via raw/jsDelivr (sem rate limit da API) com guess de path."""
    src = meta.get("source") or {}
    owner = src.get("owner")
    repo = src.get("repo")
    branch = src.get("branch") or "main"
    # Mesma versão da materialização: SHA do commit quando existe; branch só como fallback.
    ref = str(src.get("commit_sha") or "") or branch
    if not owner or not repo:
        return {}
    files = (meta.get("map") or {}).get("files") or []
    known = [f["path"] for f in files]

    out: dict[str, str] = {}
    semaphore = asyncio.Semaphore(6)

    # SHA do commit primeiro (mesma versão da materialização); branch como fallback.
    refs = [ref] + ([branch] if branch != ref else [])

    async def _fetch_once(path: str, r: str) -> tuple[str, str]:
        if meta.get("github_raw_only") and not known:
            # Sem a árvore da API não há basenames para procurar. Os candidatos
            # raw-only já são paths completos e são consultados diretamente.
            text = await fetch_file_content(owner, repo, path, ref=r)
            return (path if text else ""), text
        real, text = await fetch_file_with_path_guess(
            owner, repo, path, ref=r, known_paths=known or None
        )
        if not text:
            text = await fetch_file_content(owner, repo, path, ref=r)
        return real, text

    async def _load_one(path: str) -> tuple[str, str, str]:
        path = (path or "").strip().lstrip("./")
        if not path or is_sensitive_file(path):
            return path, "", ""
        async with semaphore:
            for r in refs:
                try:
                    real, text = await _fetch_once(path, r)
                except Exception as e:
                    logger.warning("github fetch %s@%s: %s", path, r, e)
                    continue
                if text:
                    return path, real, text
            return path, "", ""

    results = await asyncio.gather(*(_load_one(path) for path in dict.fromkeys(paths)))
    for path, real, text in results:
        if text:
            out[path] = text
            if real:
                out[real] = text
    if not out:
        logger.warning(
            "github: nenhum arquivo carregado para %s/%s (ref=%s, branch=%s, raw_only=%s); "
            "verifique rate limit da API e conectividade com raw/jsDelivr",
            owner, repo, ref, branch, bool(meta.get("github_raw_only")),
        )
    return out


def build_query_context(
    project_id: str,
    query: str,
    *,
    max_tokens: int = 4500,
    extra_paths: Optional[list[str]] = None,
    level: Optional[str] = None,
) -> str:
    """API síncrona (compat Project Analyzer). Para GitHub lazy, usa cache local se houver."""
    meta = load_meta(project_id)
    if not meta:
        return (
            f"(Code Analyzer: projeto {project_id} não encontrado ou expirado. "
            "Envie o ZIP/GitHub de novo.)"
        )

    level = level or detect_level(query)
    src_type = (meta.get("source") or {}).get("type", "zip")

    # PDF path
    if src_type in {"pdf", "docx"} or meta.get("pdf_pages") or meta.get("document_pages"):
        pages = meta.get("document_pages") or meta.get("pdf_pages") or []
        ranked = search_pages(pages, query, top_k=18 if level == "deep" else 10)
        if extra_paths:
            have = {r["path"] for r in ranked}
            for ep in extra_paths:
                for p in pages:
                    if p["path"] == ep and ep not in have:
                        ranked.insert(
                            0,
                            {
                                "path": ep,
                                "score": 999,
                                "text": p["text"],
                                "important": True,
                            },
                        )
        map_data = meta.get("map") or pages_to_map(pages)
        extraction = meta.get("pdf_extraction") or map_data.get("pdf_extraction") or {}
        ranked = rank_for_query(ranked, query, level=level)
        context = build_context(
            map_data,
            ranked,
            query,
            max_tokens=max_tokens,
            level=level,
            source_label="Code Analyzer / DOCX" if src_type == "docx" else "Code Analyzer / PDF",
        )
        if src_type == "pdf" and extraction:
            context += (
                "\n\n[PDF: páginas com OCR=" + str(extraction.get("ocr_pages", 0))
                + "; páginas digitalizadas detectadas=" + str(extraction.get("scanned_pages", 0))
                + "; páginas sem leitura=" + str(extraction.get("unreadable_pages", 0))
                + "; limite de páginas atingido=" + str(bool(extraction.get("page_limit_reached")))
                + ". Cite somente páginas cujo texto esteja incluído no contexto.]"
            )
        return context

    map_data = meta.get("map") or {"files": [], "file_count": 0}
    original_files = map_data.get("files") or []
    files = [f for f in original_files if not is_sensitive_file(str(f.get("path") or ""))]
    if len(files) != len(original_files):
        map_data = {**map_data, "files": files, "file_count": len(files)}
    symbol_index = meta.get("symbols") or {}

    # GitHub lazy: sem arquivos no disco — só ranking por path/símbolos limitados
    if meta.get("github_lazy") or src_type == "github":
        # score only by path + known symbols (conteúdo sob demanda via async path)
        from .code_search import expand_query, score_file

        terms = expand_query(query)
        ranked_meta = []
        for fm in files:
            sc = score_file(fm["path"], "", terms, bool(fm.get("important")), symbol_index.get(fm["path"]))
            # path-only scoring boost
            pl = fm["path"].lower()
            for t in terms:
                if t in pl:
                    sc += 4.0
            if sc > 0 or fm.get("important"):
                ranked_meta.append({**fm, "score": sc, "text": ""})
        ranked_meta.sort(key=lambda x: -x["score"])
        ranked_meta = rank_for_query(ranked_meta, query, level=level)

        # tentar ler do workspace se já baixado em sessão anterior
        scan = _scan_root_for(project_id, meta)
        for item in ranked_meta:
            p = scan / item["path"]
            if p.is_file():
                try:
                    item["text"] = p.read_text(encoding="utf-8", errors="replace")[:200_000]
                except Exception:
                    pass

        # se extra_paths, incluir
        if extra_paths:
            have = {r["path"] for r in ranked_meta}
            for ep in extra_paths:
                ep = ep.strip().lstrip("./")
                if not ep or is_sensitive_file(ep) or ep in have:
                    continue
                ranked_meta.insert(
                    0,
                    {"path": ep, "score": 999, "important": True, "text": ""},
                )

        follow = suggest_followup_paths(ranked_meta, files, query)
        # nota: conteúdo GitHub completo prefere build_query_context_async
        missing = [r["path"] for r in ranked_meta if not r.get("text")]
        note = ""
        if missing:
            note = (
                "\n\n[Nota Code Analyzer: alguns arquivos GitHub ainda não foram baixados "
                f"neste turno: {', '.join(missing[:8])}. "
                "Use a rota async ou peça paths específicos.]"
            )
        ctx = build_context(
            map_data,
            [r for r in ranked_meta if r.get("text")],
            query,
            max_tokens=max_tokens,
            level=level,
            source_label="Code Analyzer / GitHub",
            followup_paths=follow,
        )
        return ctx + note

    # ZIP / direct (disco local)
    scan = _scan_root_for(project_id, meta)
    ranked = search_files(
        scan, files, query, top_k=24 if level == "deep" else 18, symbol_index=symbol_index
    )

    # paths extras explícitos + nomes de arquivo mencionados na pergunta
    have = {r["path"] for r in ranked}
    auto_paths: list[str] = list(extra_paths or [])
    mentioned = extract_mentioned_filenames(query)
    if mentioned:
        auto_paths.extend(find_matching_paths(files, mentioned))
    for ep in auto_paths:
        ep = (ep or "").strip().lstrip("./").replace("\\", "/")
        if not ep or is_sensitive_file(ep) or ep in have:
            continue
        p = scan / ep
        if p.is_file():
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
                ranked.insert(
                    0,
                    {
                        "path": ep,
                        "score": 999,
                        "important": True,
                        "text": text,
                        "forced": True,
                    },
                )
                have.add(ep)
            except Exception:
                pass
        else:
            # tenta achar por basename em qualquer subpasta
            base = Path(ep).name.lower()
            for fm in files:
                if Path(fm["path"]).name.lower() == base or _stem_close(fm["path"], ep):
                    cand = scan / fm["path"]
                    if cand.is_file() and fm["path"] not in have:
                        try:
                            text = cand.read_text(encoding="utf-8", errors="replace")
                            ranked.insert(
                                0,
                                {
                                    "path": fm["path"],
                                    "score": 999,
                                    "important": True,
                                    "text": text,
                                    "forced": True,
                                },
                            )
                            have.add(fm["path"])
                        except Exception:
                            pass
                        break

    # dependency resolver (não remove arquivos forced)
    ranked = resolve_dependencies(scan, ranked, symbol_index, files, max_extra=8 if level != "quick" else 3)
    ranked = rank_for_query(ranked, query, level=level)
    # garante que forced fiquem no topo mesmo após rank
    ranked.sort(key=lambda r: (0 if r.get("forced") else 1, -float(r.get("score") or 0)))
    follow = suggest_followup_paths(ranked, files, query) if level != "quick" else []

    # pedido de conteúdo completo → orçamento alto
    if _wants_full_file(query):
        max_tokens = min(max(max_tokens, 6000), 8000)
        level = "deep"
    elif level == "deep":
        max_tokens = min(max(max_tokens, 4500), 7000)

    return build_context(
        map_data,
        ranked,
        query,
        max_tokens=max_tokens,
        level=level,
        source_label="Code Analyzer",
        followup_paths=follow,
    )


async def build_query_context_async(
    project_id: str,
    query: str,
    *,
    max_tokens: int = 4500,
    extra_paths: Optional[list[str]] = None,
    level: Optional[str] = None,
) -> str:
    """Versão async: para GitHub baixa só os blobs necessários."""
    meta = load_meta(project_id)
    if not meta:
        return build_query_context(project_id, query, max_tokens=max_tokens, extra_paths=extra_paths, level=level)

    src_type = (meta.get("source") or {}).get("type", "zip")
    if src_type != "github" and not meta.get("github_lazy"):
        return build_query_context(
            project_id, query, max_tokens=max_tokens, extra_paths=extra_paths, level=level
        )

    level = level or detect_level(query)
    map_data = meta.get("map") or {"files": [], "file_count": 0}
    original_files = map_data.get("files") or []
    files = [f for f in original_files if not is_sensitive_file(str(f.get("path") or ""))]
    if len(files) != len(original_files):
        map_data = {**map_data, "files": files, "file_count": len(files)}
    symbol_index = meta.get("symbols") or {}

    from .code_search import expand_query, score_file

    terms = expand_query(query)
    ranked_meta = []
    scope_prefix = str((meta.get("source") or {}).get("path_prefix") or "").strip(" /")
    for fm in files:
        sc = score_file(fm["path"], "", terms, bool(fm.get("important")), symbol_index.get(fm["path"]))
        pl = fm["path"].lower()
        for t in terms:
            if t in pl:
                sc += 4.0
        if scope_prefix and (pl == scope_prefix.lower() or pl.startswith(scope_prefix.lower() + "/")):
            sc += 12.0
        if sc > 0 or fm.get("important"):
            ranked_meta.append({**fm, "score": sc})
    ranked_meta.sort(key=lambda x: -x["score"])
    ranked_meta = rank_for_query(ranked_meta, query, level=level)

    # Resolve nomes soltos (attachment_service.dart) → path completo no tree
    forced_paths: set[str] = set()
    from .code_search import find_matching_paths, extract_mentioned_filenames

    requested_paths = list(extra_paths or [])
    requested_paths.extend(extract_mentioned_filenames(query))
    from .source_detector import extract_need_more_paths

    requested_paths.extend(extract_need_more_paths(query))
    requested_paths = [path for path in requested_paths if not is_sensitive_file(str(path or ""))]
    if requested_paths:
        resolved: list[str] = []
        for ep in requested_paths:
            ep = (ep or "").strip().lstrip("./")
            if not ep:
                continue
            # match exato
            exact = [f["path"] for f in files if f["path"] == ep or f["path"].endswith("/" + ep)]
            if exact:
                resolved.extend(exact)
                forced_paths.update(exact)
                continue
            # basename / fuzzy
            matches = find_matching_paths(files, [ep])
            if matches:
                resolved.extend(matches)
                forced_paths.update(matches)
            else:
                resolved.append(ep)  # tenta path cru mesmo assim
                forced_paths.add(ep)

        # dedupe preservando ordem
        seen = set()
        ordered = []
        for r in resolved:
            if r not in seen:
                seen.add(r)
                ordered.append(r)

        have = {r["path"] for r in ranked_meta}
        for ep in ordered:
            if ep not in have:
                ranked_meta.insert(
                    0, {"path": ep, "score": 999, "important": True, "forced": True}
                )
            else:
                for r in ranked_meta:
                    if r["path"] == ep:
                        r["score"] = 999
                        r["forced"] = True
                        r["important"] = True
        # forced no topo
        ranked_meta.sort(key=lambda r: (0 if r.get("forced") else 1, -float(r.get("score") or 0)))

    # sempre prioriza forced / high score no fetch
    # deep mode puxa mais arquivos para análise de melhorias / code review
    paths = []
    candidate_limit = 24 if level == "deep" else (16 if level == "targeted" else 10)
    for r in ranked_meta:
        if r["path"] not in paths:
            paths.append(r["path"])
        if len(paths) >= candidate_limit:
            break
    # garante extra_paths no fetch mesmo se ranking os empurrou
    if requested_paths:
        for ep in requested_paths:
            ep = (ep or "").strip().lstrip("./")
            if not ep:
                continue
            matches = [
                f["path"]
                for f in files
                if f["path"] == ep
                or f["path"].endswith("/" + ep)
                or Path(f["path"]).name.lower() == Path(ep).name.lower()
            ]
            for m in matches or [ep]:
                if m not in paths:
                    paths.insert(0, m)

    # Sem árvore (rate limit): tenta nomes pedidos na query
    if not paths:
        from .code_search import extract_mentioned_filenames
        import re as _re
        mentioned = extract_mentioned_filenames(query)
        paths = list(mentioned or [])
        if extra_paths:
            for ep in extra_paths:
                ep = (ep or "").strip().lstrip("./")
                if ep and ep not in paths:
                    paths.append(ep)
        if not paths:
            paths = _re.findall(
                r"\b([\w./\-]+\.(?:dart|py|js|ts|tsx|jsx|java|kt|go|rs|swift|cs))\b",
                query or "",
            )
    if not paths and meta.get("github_raw_only") and not files:
        # GitHub API 403/429 deixa o projeto sem árvore. Ainda tentamos uma
        # amostra de entrypoints/manifests comuns para oferecer análise parcial.
        # Expandido para cobrir mais stacks (Flutter, Node, Python, Go, Rust, Java).
        paths = [
            "README.md",
            "pubspec.yaml",
            "package.json",
            "pyproject.toml",
            "requirements.txt",
            "go.mod",
            "Cargo.toml",
            "pom.xml",
            "build.gradle",
            "Dockerfile",
            "docker-compose.yml",
            "lib/main.dart",
            "lib/app.dart",
            "src/main.dart",
            "src/App.tsx",
            "src/App.jsx",
            "src/index.ts",
            "src/index.js",
            "src/main.py",
            "main.py",
            "app.py",
            "main.js",
            "main.ts",
            "index.html",
            "backend/app/main.py",
            "backend/main.py",
            "app/main.py",
            "cmd/main.go",
            "main.go",
        ]
        logger.warning(
            "github raw-only fallback: probing %d conventional repository paths for %s/%s",
            len(paths),
            (meta.get("source") or {}).get("owner"),
            (meta.get("source") or {}).get("repo"),
        )

    texts = await _load_github_texts(meta, paths[:32])

    # cache no workspace para próximas queries
    scan = workspace(project_id)
    for path, text in texts.items():
        try:
            target = scan / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        except Exception:
            pass

    ranked = []
    for r in ranked_meta:
        text = texts.get(r["path"], "")
        if not text:
            continue
        content_score = score_file(
            r["path"],
            text,
            terms,
            bool(r.get("important")),
            symbol_index.get(r["path"]),
        )
        is_forced = r["path"] in forced_paths or bool(r.get("forced"))
        ranked.append(
            {
                **r,
                "score": 999.0 if is_forced else content_score,
                "text": text,
                "preview": text[:400],
                "forced": is_forced,
            }
        )

    # raw-only / rate limit: textos baixados sem entrada no ranked_meta
    if texts and not ranked:
        for path, text in texts.items():
            if not text:
                continue
            ranked.append(
                {
                    "path": path,
                    "score": 999.0 if path in forced_paths else score_file(path, text, terms),
                    "important": path in forced_paths,
                    "forced": path in forced_paths,
                    "text": text,
                    "preview": text[:400],
                }
            )
        # dedupe por path
        seen = set()
        uniq = []
        for r in ranked:
            if r["path"] in seen:
                continue
            seen.add(r["path"])
            uniq.append(r)
        ranked = uniq

    # deps: com textos, resolver localmente
    if ranked:
        ranked = resolve_dependencies(scan, ranked, symbol_index, files, max_extra=6)
        # baixar deps que faltaram
        need = [r["path"] for r in ranked if r["path"] not in texts]
        if need:
            more = await _load_github_texts(meta, need[:8])
            for path, text in more.items():
                texts[path] = text
                try:
                    (scan / path).parent.mkdir(parents=True, exist_ok=True)
                    (scan / path).write_text(text, encoding="utf-8")
                except Exception:
                    pass
            for r in ranked:
                if not r.get("text") and r["path"] in texts:
                    r["text"] = texts[r["path"]]

    ranked = rank_for_query(ranked, query, level=level)
    ranked.sort(key=lambda item: (0 if item.get("forced") else 1, -float(item.get("score") or 0)))
    follow = suggest_followup_paths(ranked, files, query)

    context = build_context(
        map_data,
        ranked,
        query,
        max_tokens=min(max_tokens if level != "deep" else max(max_tokens, 5000), 8000),
        level=level,
        source_label="Code Analyzer / GitHub",
        followup_paths=follow,
    )
    if meta.get("github_raw_only"):
        context += (
            "\n\n[GitHub: a API não forneceu a árvore do repositório. Os arquivos incluídos "
            "foram encontrados por caminhos convencionais e representam apenas uma amostra. "
            "Faça uma análise útil do código realmente incluído, identifique a cobertura parcial "
            "e recomende GITHUB_TOKEN ou envio do ZIP para revisar o restante.]"
        )
    missing_requested = sorted(path for path in forced_paths if path not in texts)
    if missing_requested:
        oversized = set((meta.get("source") or {}).get("oversized_files") or [])
        oversized_requested = [path for path in missing_requested if path in oversized]
        if oversized_requested:
            context += (
                "\n\n[GitHub: estes arquivos excedem o limite de leitura por arquivo ("
                f"{MAX_TEXT_FILE_BYTES // 1_000_000} MB): "
                + ", ".join(oversized_requested[:12])
                + ". Peça um recorte/intervalo ou envie o arquivo em partes.]"
            )
            missing_requested = [path for path in missing_requested if path not in oversized]
    if missing_requested:
        context += (
            "\n\n[GitHub: não consegui carregar os caminhos solicitados: "
            + ", ".join(missing_requested[:12])
            + ". Não afirme ter lido esses arquivos. Verifique branch/permissão ou peça um link acessível.]"
        )
    elif paths and not texts:
        context += (
            "\n\n[GitHub: não foi possível baixar nenhum dos arquivos candidatos neste turno. "
            "A árvore pode estar acessível enquanto o conteúdo está bloqueado por rate limit, "
            "permissão, referência ou indisponibilidade do raw/CDN. Não afirme ter lido o código; "
            "peça um link direto ou o arquivo enviado pelo usuário.]"
        )
    if meta.get("github_tree_partial"):
        context += (
            "\n\n[GitHub: a árvore foi limitada por tamanho; os paths indexados são uma amostra. "
            "Use um link direto para arquivo/pasta quando faltar contexto.]"
        )
    return context


async def detect_and_prepare(
    user_text: str,
    *,
    user_id: str = "default",
) -> Optional[dict[str, Any]]:
    """Detecta GitHub URL na mensagem e ingere se necessário. Retorna summary ou None."""
    gh = parse_github_url(user_text)
    if not gh:
        return None
    try:
        return await ingest_github(
            gh["owner"],
            gh["repo"],
            branch=gh.get("branch") or "main",
            path_prefix=(gh.get("path") or "") if gh.get("object_type") == "tree" else "",
            user_id=user_id,
        )
    except Exception as e:
        logger.warning("github ingest failed: %s", e)
        return {"error": str(e), "source": "github"}


def build_coverage_report(project_id: str, context: str, *, level: Optional[str] = None) -> dict[str, Any]:
    """Resume a cobertura real do contexto enviado ao modelo, sem alegar revisão integral."""
    from .index_store import load_meta

    meta = load_meta(project_id) or {}
    map_data = meta.get("map") or {}
    source = meta.get("source") or {}
    indexed = map_data.get("files") or []
    indexed_paths = [
        str(item.get("path", ""))
        for item in indexed
        if item.get("path") and not is_sensitive_file(str(item.get("path", "")))
    ]

    included: list[str] = []
    for match in re.finditer(r"^###\s+(.+?)\s+—\s+(?:linhas|página|trecho)\b", context or "", re.MULTILINE | re.IGNORECASE):
        path = match.group(1).strip()
        path = re.sub(r"\s+\(dep\)$", "", path)
        path = re.sub(r"\s+\[arquivo pedido\]$", "", path)
        if path and path not in included:
            included.append(path)

    omitted = [path for path in indexed_paths if path not in set(included)]
    text = context or ""
    truncation_markers = (
        "linhas omitidas", "arquivo com ", "trechos enviados=", "texto enviado=",
        "alguns arquivos GitHub ainda não foram baixados", "limite de páginas atingido=True",
        "limite de contexto", "[nenhum trecho de arquivo foi incluído",
    )
    truncated = any(marker in text.lower() for marker in truncation_markers)
    source_partial = bool(meta.get("github_tree_partial") or source.get("raw_only") or meta.get("github_raw_only"))
    has_evidence = bool(included) and "nenhum trecho de arquivo foi incluído" not in text.lower()
    no_project_files = not indexed_paths
    exhaustive = bool(indexed_paths) and not omitted and not truncated and not source_partial
    if not has_evidence:
        status = "sem_evidencias"
    elif exhaustive:
        status = "todos_os_arquivos_indexados_incluidos"
    else:
        status = "parcial"

    warnings: list[str] = []
    if omitted:
        warnings.append(f"{len(omitted)} arquivo(s) indexado(s) não foram incluídos no contexto deste turno.")
    if truncated:
        warnings.append("Um ou mais arquivos/trechos foram truncados ou tiveram linhas omitidas pelo orçamento de contexto.")
    if source_partial:
        warnings.append("A origem GitHub possui árvore parcial, modo raw-only ou limitações conhecidas.")
    if not has_evidence:
        warnings.append("Nenhuma evidência de arquivo foi confirmada no contexto; não trate a resposta como análise do código-fonte.")
    if has_evidence and not exhaustive:
        warnings.append("Esta é uma análise seletiva, não uma auditoria integral do projeto.")
    return {
        "status": status,
        "source_type": source.get("type", "unknown"),
        "level": level or "auto",
        "indexed_file_count": int(map_data.get("file_count") or len(indexed_paths)),
        "included_file_count": len(included),
        "included_paths": included[:200],
        "omitted_file_count": len(omitted),
        "omitted_paths_sample": omitted[:50],
        "context_chars": len(text),
        "context_has_truncation_markers": truncated,
        "source_index_partial": source_partial,
        "full_project_review": exhaustive,
        "warnings": warnings,
    }
