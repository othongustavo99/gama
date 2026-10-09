"""Orquestra Code Analyzer: ingestão + busca + deps + relevância + contexto.

Níveis: quick | targeted | deep
Fontes: zip | github | pdf | direct
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Optional

from .code_search import search_files, extract_mentioned_filenames, find_matching_paths
from .context_builder import build_context
from .dependency_resolver import resolve_dependencies
from .extractor import safe_extract
from .github_reader import fetch_file_content, get_tree
from .index_store import (
    cleanup_old,
    find_github_cache,
    load_meta,
    new_project_id,
    save_meta,
    workspace,
)
from .mapper import build_symbol_index, walk_project
from .pdf_reader import extract_pages, pages_to_map, search_pages
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
        "completo e literal", "o que tem dentro", "me diga exatamente", "full content",
        "entire file", "whole file",
    )
    return any(k in q for k in keys)


def _scan_root_for(project_id: str, meta: dict[str, Any]) -> Path:
    root = workspace(project_id)
    rel = meta.get("scan_root") or "."
    if rel in (".", "", None):
        children = [p for p in root.iterdir()] if root.exists() else []
        if len(children) == 1 and children[0].is_dir():
            return children[0]
        return root
    return root / rel


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
    }


async def ingest_github(
    owner: str,
    repo: str,
    *,
    branch: str = "main",
    user_id: str = "default",
) -> dict[str, Any]:
    """Indexa árvore do GitHub sem baixar o repo inteiro. Arquivos sob demanda."""
    cleanup_old()
    tree_sha, entries = await get_tree(owner, repo, branch)

    cached = find_github_cache(owner, repo, branch, tree_sha)
    if cached:
        summary = get_project_summary(cached)
        if summary:
            return {**summary, "cached": True, "source": "github"}

    project_id = new_project_id()
    # materializa só metadados (sem conteúdo ainda)
    # filtra como cleaner faria
    from .cleaner import should_skip_dir, should_skip_file
    from pathlib import PurePosixPath

    files: list[dict[str, Any]] = []
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
        if e.get("size", 0) > 1_500_000:
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
            "owner": owner,
            "repo": repo,
            "branch": branch,
            "tree_sha": tree_sha,
            "key": f"{owner}/{repo}@{branch}".lower(),
        },
        "scan_root": ".",
        "map": map_data,
        "symbols": {},  # preenchido sob demanda / partial
        "github_lazy": True,
    }
    save_meta(project_id, meta)
    # workspace vazio — conteúdo vem da API
    workspace(project_id).mkdir(parents=True, exist_ok=True)

    return {
        "project_id": project_id,
        "name": f"{owner}/{repo}",
        "source": "github",
        "branch": branch,
        "file_count": map_data["file_count"],
        "frameworks": map_data["frameworks"],
        "languages": map_data["languages"],
        "sample_paths": [f["path"] for f in files[:25]],
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
    pages = extract_pages(pdf_bytes)
    if not pages:
        raise ValueError("PDF sem texto extraível")

    map_data = pages_to_map(pages)
    # guarda páginas no meta (texto já extraído)
    meta = {
        "name": name,
        "user_id": user_id,
        "source": {"type": "pdf", "name": name},
        "scan_root": ".",
        "map": map_data,
        "symbols": {},
        "pdf_pages": pages,
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
    }


# ─── Query context ────────────────────────────────────────────────────────


async def _load_github_texts(
    meta: dict[str, Any],
    paths: list[str],
) -> dict[str, str]:
    src = meta.get("source") or {}
    owner = src.get("owner")
    repo = src.get("repo")
    branch = src.get("branch") or "main"
    if not owner or not repo:
        return {}
    out: dict[str, str] = {}
    for path in paths:
        try:
            text = await fetch_file_content(owner, repo, path, ref=branch)
            if text:
                out[path] = text
        except Exception as e:
            logger.warning("github fetch %s: %s", path, e)
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
    if src_type == "pdf" or meta.get("pdf_pages"):
        pages = meta.get("pdf_pages") or []
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
        ranked = rank_for_query(ranked, query, level=level)
        return build_context(
            map_data,
            ranked,
            query,
            max_tokens=max_tokens,
            level=level,
            source_label="Code Analyzer / PDF",
        )

    map_data = meta.get("map") or {"files": [], "file_count": 0}
    files = map_data.get("files") or []
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
                if not ep or ep in have:
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
        if not ep or ep in have:
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
    files = map_data.get("files") or []
    symbol_index = meta.get("symbols") or {}

    from .code_search import expand_query, score_file

    terms = expand_query(query)
    ranked_meta = []
    for fm in files:
        sc = score_file(fm["path"], "", terms, bool(fm.get("important")), symbol_index.get(fm["path"]))
        pl = fm["path"].lower()
        for t in terms:
            if t in pl:
                sc += 4.0
        if sc > 0 or fm.get("important"):
            ranked_meta.append({**fm, "score": sc})
    ranked_meta.sort(key=lambda x: -x["score"])
    ranked_meta = rank_for_query(ranked_meta, query, level=level)

    if extra_paths:
        have = {r["path"] for r in ranked_meta}
        for ep in extra_paths:
            ep = ep.strip().lstrip("./")
            if ep and ep not in have:
                ranked_meta.insert(0, {"path": ep, "score": 999, "important": True})

    paths = [r["path"] for r in ranked_meta[:18]]
    texts = await _load_github_texts(meta, paths)

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
        ranked.append({**r, "text": text, "preview": text[:400]})

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
    follow = suggest_followup_paths(ranked, files, query)

    return build_context(
        map_data,
        ranked,
        query,
        max_tokens=min(max_tokens if level != "deep" else max(max_tokens, 5000), 8000),
        level=level,
        source_label="Code Analyzer / GitHub",
        followup_paths=follow,
    )


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
            gh["owner"], gh["repo"], branch=gh.get("branch") or "main", user_id=user_id
        )
    except Exception as e:
        logger.warning("github ingest failed: %s", e)
        return {"error": str(e), "source": "github"}
