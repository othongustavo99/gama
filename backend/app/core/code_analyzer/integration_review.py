"""Deterministic cross-subsystem map for Code Analyzer deep reviews.

This module complements (but does not replace) the LLM's code review. It reports
only relationships that can be inferred from indexed paths and readable source.
"""
from __future__ import annotations

import re
from pathlib import Path, PurePosixPath
from typing import Any

from .index_store import load_meta, workspace
from .pipeline import _scan_root_for

_IMPORT_PATTERNS = (
    # Python
    re.compile(r"^\s*from\s+([A-Za-z_][\w.]*)\s+import\s+", re.M),
    re.compile(r"^\s*import\s+([A-Za-z_][\w.]*)", re.M),
    # JavaScript / TypeScript
    re.compile(r"\b(?:import|export)\b[^\n;]*?\bfrom\s*[\"']([^\"']+)[\"']", re.M),
    re.compile(r"\brequire\(\s*[\"']([^\"']+)[\"']\s*\)", re.M),
    # Dart / Flutter
    re.compile(r"^\s*(?:import|export|part)\s+[\"']([^\"']+)[\"']", re.M),
    # Java/Kotlin/C#-style namespaces are considered weak evidence only.
    re.compile(r"^\s*import\s+([A-Za-z_][\w.]*)\s*;?\s*$", re.M),
)


def _category(path: str) -> str:
    p = path.lower().replace("\\", "/")
    name = PurePosixPath(p).name
    if any(x in p for x in ("/test/", "/tests/", "/spec/")) or name.startswith(("test_", "*_test.")) or ".test." in name or ".spec." in name:
        return "tests"
    if any(x in p for x in ("auth", "security", "identity", "login", "permission", "token")):
        return "security"
    if any(x in p for x in ("route", "controller", "endpoint", "/api/", "handler")):
        return "api"
    if any(x in p for x in ("repository", "database", "storage", "dao", "model", "memory", "store")):
        return "persistence"
    if any(x in p for x in ("service", "client", "provider", "network", "http", "dio")):
        return "services"
    if any(x in p for x in ("screen", "widget", "page", "view", "component", "frontend", "web/")):
        return "ui"
    if name in {"main.py", "main.dart", "main.js", "main.ts", "app.py", "app.dart", "index.js", "index.ts"}:
        return "entrypoints"
    if name in {"pubspec.yaml", "package.json", "requirements.txt", "pyproject.toml", "dockerfile", "docker-compose.yml"}:
        return "configuration"
    return "other"


def _readable_sources(project_id: str, meta: dict[str, Any], limit: int) -> dict[str, str]:
    source = meta.get("source") or {}
    scan = (_scan_root_for(project_id, meta) if source.get("type") != "github" and not meta.get("github_lazy") else workspace(project_id)).resolve()
    result: dict[str, str] = {}
    files = (meta.get("map") or {}).get("files") or []
    for item in files[:limit]:
        path = str(item.get("path") or "")
        pure = PurePosixPath(path)
        if not path or pure.is_absolute() or any(part in {"..", "."} for part in pure.parts):
            continue
        target = (scan / Path(*pure.parts)).resolve()
        if scan not in target.parents or not target.is_file():
            continue
        try:
            if target.stat().st_size > 1_500_000:
                continue
            text = target.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if text.strip():
            result[path] = text
    return result


def _import_refs(text: str) -> list[str]:
    found: list[str] = []
    for pattern in _IMPORT_PATTERNS:
        for match in pattern.findall(text or ""):
            value = str(match).strip()
            if value and value not in found:
                found.append(value)
    return found[:150]


def _resolve_local_import(path: str, ref: str, all_paths: set[str]) -> str | None:
    ref = ref.strip().replace("\\", "/")
    if not ref or ref.startswith(("http:", "https:")):
        return None
    # Dart package:foo/bar.dart -> path suffix under a package or lib directory.
    if ref.startswith("package:"):
        tail = ref[len("package:"):]
        candidates = [p for p in all_paths if p == tail or p.endswith("/" + tail)]
        return candidates[0] if len(candidates) == 1 else None
    current_dir = str(PurePosixPath(path).parent)
    candidates: list[str] = []
    if ref.startswith("."):
        base = (PurePosixPath(current_dir) / ref)
        normalized = str(base)
        parts: list[str] = []
        for item in PurePosixPath(normalized).parts:
            if item == ".":
                continue
            if item == "..":
                if parts:
                    parts.pop()
            else:
                parts.append(item)
        stem = "/".join(parts)
        candidates.extend([stem, stem + ".py", stem + ".dart", stem + ".js", stem + ".ts", stem + ".tsx", stem + ".jsx", stem + "/index.js", stem + "/index.ts"])
    elif "." in ref and "/" not in ref and not ref.startswith(("@", "#")):
        # Python dotted module names.
        dotted = ref.replace(".", "/")
        candidates.extend([dotted + ".py", dotted + "/__init__.py"])
    elif ref.startswith(("src/", "lib/", "app/", "backend/", "frontend/")):
        candidates.extend([ref, ref + ".py", ref + ".dart", ref + ".js", ref + ".ts"])
    else:
        return None
    for candidate in candidates:
        if candidate in all_paths:
            return candidate
    # Last-resort suffix resolution only for explicitly local imports.
    if ref.startswith("."):
        tail = PurePosixPath(ref).name
        matching = [p for p in all_paths if PurePosixPath(p).name == tail or PurePosixPath(p).stem == tail]
        if len(matching) == 1:
            return matching[0]
    return None


def build_integration_map(project_id: str, *, max_files: int = 1000) -> dict[str, Any]:
    """Build a source-backed import map and subsystem overview."""
    meta = load_meta(project_id) or {}
    indexed = (meta.get("map") or {}).get("files") or []
    paths = [str(item.get("path") or "") for item in indexed if item.get("path")]
    path_set = set(paths)
    readable = _readable_sources(project_id, meta, max_files)
    edges: list[dict[str, str]] = []
    unresolved: list[dict[str, str]] = []
    category_counts: dict[str, int] = {}
    for path in paths:
        cat = _category(path)
        category_counts[cat] = category_counts.get(cat, 0) + 1
    for path, text in readable.items():
        for ref in _import_refs(text):
            target = _resolve_local_import(path, ref, path_set)
            if target and target != path:
                edge = {"from": path, "to": target, "import": ref}
                if edge not in edges:
                    edges.append(edge)
            elif ref.startswith((".", "package:")) or ref.startswith(("src/", "lib/", "app/", "backend/", "frontend/")):
                unresolved.append({"from": path, "import": ref})
    indegree: dict[str, int] = {}
    outdegree: dict[str, int] = {}
    for edge in edges:
        indegree[edge["to"]] = indegree.get(edge["to"], 0) + 1
        outdegree[edge["from"]] = outdegree.get(edge["from"], 0) + 1
    central = sorted(
        ({"path": p, "incoming": indegree.get(p, 0), "outgoing": outdegree.get(p, 0)} for p in set(indegree) | set(outdegree)),
        key=lambda item: (-(item["incoming"] + item["outgoing"]), item["path"]),
    )[:30]

    # Link conventional tests to source modules by basename, without pretending
    # that name matching proves the tests cover the implementation.
    source_by_stem: dict[str, list[str]] = {}
    test_paths = [p for p in paths if _category(p) == "tests"]
    for path in paths:
        if _category(path) == "tests":
            continue
        stem = PurePosixPath(path).stem.lower()
        source_by_stem.setdefault(stem, []).append(path)
    test_links: list[dict[str, str]] = []
    for test_path in test_paths:
        test_stem = PurePosixPath(test_path).stem.lower()
        normalized = test_stem.removeprefix("test_").removesuffix("_test").removesuffix(".test").removesuffix(".spec")
        for stem, source_matches in source_by_stem.items():
            if normalized and (normalized == stem or normalized in stem or stem in normalized):
                for source_path in source_matches[:2]:
                    test_links.append({"test": test_path, "source": source_path})
                break
        if len(test_links) >= 50:
            break

    return {
        "project_id": project_id,
        "indexed_file_count": len(paths),
        "readable_file_count": len(readable),
        "unreadable_or_not_materialized_count": max(0, len(paths) - len(readable)),
        "category_counts": category_counts,
        "edge_count": len(edges),
        "edges": edges[:400],
        "central_files": central,
        "unresolved_local_imports": unresolved[:100],
        "test_source_name_matches": test_links,
        "read_paths": list(readable)[:300],
        "source_tree_partial": bool(meta.get("github_tree_partial") or (meta.get("source") or {}).get("raw_only") or meta.get("github_raw_only")),
    }


def render_integration_context(report: dict[str, Any]) -> str:
    """Compact, evidence-labeled context for a cross-subsystem integration pass."""
    lines = [
        "[PASSO 3 — INTEGRAÇÃO ENTRE SUBSISTEMAS: MAPA ESTÁTICO]",
        f"Arquivos indexados={report.get('indexed_file_count', 0)}; lidos para grafo={report.get('readable_file_count', 0)}; "
        f"arestas de import identificadas={report.get('edge_count', 0)}; árvore parcial={bool(report.get('source_tree_partial'))}.",
        "O grafo é heurístico: ausência de aresta não prova ausência de dependência; nomes de testes não provam cobertura.",
        "Categorias: " + (", ".join(f"{key}={value}" for key, value in sorted((report.get("category_counts") or {}).items())) or "nenhuma"),
        "\nArquivos com maior centralidade (imports entrantes/saíntes):",
    ]
    for item in report.get("central_files") or []:
        lines.append(f"- {item['path']} (entrantes={item['incoming']}, saíntes={item['outgoing']})")
    lines.append("\nRelações entre módulos detectadas:")
    for edge in (report.get("edges") or [])[:180]:
        lines.append(f"- {edge['from']} -> {edge['to']} (import={edge['import']})")
    if report.get("unresolved_local_imports"):
        lines.append("\nImports locais não resolvidos na árvore disponível (pode ser alias, arquivo omitido ou dependência externa):")
        for item in report["unresolved_local_imports"][:60]:
            lines.append(f"- {item['from']} importa {item['import']}")
    if report.get("test_source_name_matches"):
        lines.append("\nPossíveis pares teste/implementação por nome (não equivale a comprovação de cobertura):")
        for item in report["test_source_name_matches"][:40]:
            lines.append(f"- {item['test']} <-> {item['source']}")
    if report.get("unreadable_or_not_materialized_count"):
        lines.append(
            f"\nAVISO: {report['unreadable_or_not_materialized_count']} arquivo(s) indexado(s) não estavam legíveis/materializados para este mapa. "
            "Não afirme que seus imports ou contratos foram verificados."
        )
    if report.get("source_tree_partial"):
        lines.append("AVISO: origem GitHub parcial/raw-only; o mapa pode omitir módulos relevantes.")
    return "\n".join(lines)
