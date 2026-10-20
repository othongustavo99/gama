"""Mapeia estrutura, linguagens e dependências."""

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
    ".java": "Java",
    ".kt": "Kotlin",
    ".go": "Go",
    ".rs": "Rust",
    ".swift": "Swift",
    ".cs": "C#",
    ".rb": "Ruby",
    ".php": "PHP",
    ".c": "C",
    ".cpp": "C++",
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
    return fw or ["Genérico"]


def walk_project(root: Path) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    lang_counter: Counter[str] = Counter()
    tree_dirs: set[str] = set()

    for path in root.rglob("*"):
        if path.is_dir():
            if should_skip_dir(path.name):
                # don't descend — rglob still visits; filter by parts
                continue
            continue
        # skip if any parent is skipped
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
    r"(?:class|enum|mixin|extension|typedef|interface|struct|func|function|def|fn)\s+(\w+)",
    re.M,
)
_IMPORT_RE = re.compile(
    r"""(?:import|export|from|require\(|package:)\s*['\"]?([\w\./\-:@]+)""",
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
