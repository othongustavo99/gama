"""Ignora cache, build, dependências e binários."""

from __future__ import annotations

import os
from pathlib import Path

SKIP_DIR_NAMES = {
    ".git",
    ".svn",
    ".hg",
    ".dart_tool",
    ".idea",
    ".vscode",
    ".gradle",
    "build",
    "Builds",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".tox",
    "dist",
    "coverage",
    "Pods",
    "DerivedData",
    ".pub-cache",
    "ephemeral",
    "android/.gradle",
    "ios/Pods",
    "windows/flutter/ephemeral",
    "linux/flutter/ephemeral",
    "macos/Flutter/ephemeral",
}

SKIP_FILE_SUFFIXES = {
    ".apk",
    ".aab",
    ".ipa",
    ".exe",
    ".dll",
    ".so",
    ".dylib",
    ".o",
    ".obj",
    ".class",
    ".jar",
    ".war",
    ".pyc",
    ".pyo",
    ".bin",
    ".dat",
    ".lock",  # package-lock huge; we keep pubspec.lock optionally
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".ico",
    ".svg",
    ".mp3",
    ".mp4",
    ".wav",
    ".ttf",
    ".otf",
    ".woff",
    ".woff2",
    ".pdf",
    ".zip",
    ".7z",
    ".rar",
    ".tar",
    ".gz",
}

# lockfiles úteis em tamanho moderado
KEEP_LOCK_NAMES = {"pubspec.lock", "package-lock.json", "yarn.lock", "poetry.lock"}

TEXT_SUFFIXES = {
    ".dart",
    ".py",
    ".js",
    ".ts",
    ".tsx",
    ".jsx",
    ".java",
    ".kt",
    ".kts",
    ".swift",
    ".go",
    ".rs",
    ".c",
    ".cpp",
    ".h",
    ".hpp",
    ".cs",
    ".rb",
    ".php",
    ".scala",
    ".m",
    ".mm",
    ".gradle",
    ".xml",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".md",
    ".txt",
    ".html",
    ".css",
    ".scss",
    ".sql",
    ".sh",
    ".bat",
    ".ps1",
    ".cmake",
    ".plist",
    ".rc",
    ".manifest",
    ".properties",
    ".cfg",
    ".ini",
    ".env",
    ".gitignore",
    ".gitattributes",
}

IMPORTANT_NAMES = {
    "pubspec.yaml",
    "package.json",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "pom.xml",
    "cargo.toml",
    "go.mod",
    "requirements.txt",
    "pyproject.toml",
    "dockerfile",
    "docker-compose.yml",
    "docker-compose.yaml",
    "readme.md",
    "readme",
    "makefile",
    "cmakelists.txt",
    "analysis_options.yaml",
    "androidmanifest.xml",
    "info.plist",
}


def should_skip_dir(name: str) -> bool:
    n = name.strip()
    if n in SKIP_DIR_NAMES:
        return True
    if n.startswith(".") and n not in {".github", ".vscode"}:
        # keep .github workflows maybe; skip hidden junk
        if n in {".github"}:
            return False
        return True
    return False


def should_skip_file(path: Path) -> bool:
    name = path.name
    lower = name.lower()
    suffix = path.suffix.lower()

    if lower in KEEP_LOCK_NAMES:
        return False

    if suffix in SKIP_FILE_SUFFIXES and lower not in KEEP_LOCK_NAMES:
        return True

    # huge generated
    if lower.endswith(".g.dart") or lower.endswith(".freezed.dart"):
        return False  # sometimes useful for models — keep

    if suffix and suffix not in TEXT_SUFFIXES and lower not in {
        n.lower() for n in IMPORTANT_NAMES
    }:
        # no extension or unknown binary-ish
        if suffix in {"", ".log", ".map"}:
            return True
        if suffix not in TEXT_SUFFIXES:
            return True

    return False


def is_important(path: Path) -> bool:
    return path.name.lower() in IMPORTANT_NAMES or path.suffix.lower() in {
        ".dart",
        ".py",
        ".ts",
        ".js",
        ".java",
        ".kt",
        ".go",
        ".rs",
    }
