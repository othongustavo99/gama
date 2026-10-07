"""Mapeia estrutura, linguagens, frameworks e gera índice leve de símbolos."""

from __future__ import annotations

import re
from collections import Counter
from pathlib import Path
from typing import Any

from .cleaner import is_important, should_skip_dir, should_skip_file

LANG_BY_EXT = {
    ".dart": "Dart",
    ".py": "Python",
    ".js": "JavaScript",
    ".ts": "TypeScript",
    ".tsx": "TypeScript",
    ".jsx": "JavaScript",
    ".java": "Java",
    ".kt": "Kotlin",
    ".kts": "Kotlin",
    ".go": "Go",
    ".rs": "Rust",
    ".swift": "Swift",
    ".cs": "C#",
    ".rb": "Ruby",
    ".php": "PHP",
    ".c": "C",
    ".cpp": "C++",
    ".h": "C/C++",
    ".hpp": "C++",
}


def detect_framework(root: Path, files: list[str]) -> list[str]:
    names = {Path(f).name.lower() for f in files}
    lower_paths = [f.lower() for f in files]
    fw: list[str] = []
    if "pubspec.yaml" in names:
        fw.append("Flutter/Dart")
    if "package.json" in names:
        fw.append("Node.js")
    if any("build.gradle" in p for p in lower_paths):
        fw.append("Android/Gradle")
    if "pom.xml" in names:
        fw.append("Maven/Java")
    if "cargo.toml" in names:
        fw.append("Rust/Cargo")
    if "go.mod" in names:
        fw.append("Go")
    if "requirements.txt" in names or "pyproject.toml" in names:
        fw.append("Python")
    if any("manage.py" in p for p in lower_paths):
        fw.append("Django")
    if any("fastapi" in p or "main.py" in p for p in lower_paths) and "Python" in (
        fw or ["Python"]
    ):
        if "FastAPI" not in fw:
            # só adiciona se houver indício
            pass
    return fw or ["Genérico"]


def walk_project(root: Path) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    lang_counter: Counter[str] = Counter()
    tree_dirs: set[str] = set()

    for path in root.rglob("*"):
        if path.is_dir():
            continue
        if any(should_skip_dir(p.name) for p in path.parents if p != root):
            continue
        if should_skip_file(path):
            continue
        try:
            rel = path.relative_to(root).as_posix()
        except ValueError:
            continue
        size = path.stat().st_size
        if size > 1_500_000:
            continue
        ext = path.suffix.lower()
        lang = LANG_BY_EXT.get(ext, "other")
        if lang != "other":
            lang_counter[lang] += 1
        for part in Path(rel).parts[:-1]:
            tree_dirs.add(part)
        files.append(
            {
                "path": rel,
                "size": size,
                "ext": ext,
                "lang": lang,
                "important": is_important(path),
            }
        )

    files.sort(key=lambda f: (not f["important"], f["path"]))
    return {
        "file_count": len(files),
        "languages": dict(lang_counter.most_common(12)),
        "frameworks": detect_framework(root, [f["path"] for f in files]),
        "files": files,
        "top_dirs": sorted(tree_dirs)[:40],
    }


_SYMBOL_RE = re.compile(
    r"(?:class|enum|mixin|extension|typedef|interface|struct|func|function|def|fn|type)\s+(\w+)",
    re.M,
)
_IMPORT_RE = re.compile(
    r"""(?:import|export|from|require\(|package:)\s*['\"]?([\w\./\-:@]+)""",
    re.M,
)
# Dart/Kotlin/Java method-ish
_METHOD_RE = re.compile(
    r"(?:(?:async|static|public|private|protected|override|Future|void|int|String|bool|double)\s+)+(\w+)\s*\(",
    re.M,
)


def extract_symbols(text: str, limit: int = 40) -> list[str]:
    found = _SYMBOL_RE.findall(text)
    out: list[str] = []
    for s in found:
        if s not in out:
            out.append(s)
        if len(out) >= limit:
            break
    return out


def extract_imports(text: str, limit: int = 30) -> list[str]:
    found = _IMPORT_RE.findall(text)
    out: list[str] = []
    for s in found:
        if s not in out:
            out.append(s)
        if len(out) >= limit:
            break
    return out


def extract_methods(text: str, limit: int = 30) -> list[str]:
    found = _METHOD_RE.findall(text)
    out: list[str] = []
    for s in found:
        if s not in out and len(s) > 2:
            out.append(s)
        if len(out) >= limit:
            break
    return out


def build_symbol_index(
    scan_root: Path, files: list[dict[str, Any]], max_files: int = 150
) -> dict[str, list[str]]:
    """Índice leve path → [símbolos + imports]."""
    symbol_index: dict[str, list[str]] = {}
    langs = {"Dart", "Python", "TypeScript", "JavaScript", "Java", "Kotlin", "Go", "Rust", "Swift", "C#"}
    for fmeta in files[:max_files]:
        if fmeta.get("lang") not in langs:
            continue
        p = scan_root / fmeta["path"]
        try:
            text = p.read_text(encoding="utf-8", errors="replace")[:80_000]
            symbols = extract_symbols(text) + extract_methods(text)[:10]
            imports = [f"imp:{i}" for i in extract_imports(text)[:15]]
            symbol_index[fmeta["path"]] = symbols + imports
        except Exception:
            pass
    return symbol_index
