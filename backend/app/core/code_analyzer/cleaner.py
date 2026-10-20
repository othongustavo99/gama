"""Regras de limpeza: o que ignorar vs. o que preservar.

Não exclui cegamente. Configurações importantes sempre ficam.
"""

from __future__ import annotations

from pathlib import Path


# Templates podem ser compartilhados; arquivos com credenciais reais não.
_SAFE_SECRET_TEMPLATES = {
    ".env.example", ".env.sample", ".env.template", ".env.dist",
    "example.env", "sample.env", "credentials.example.json",
    "service-account.example.json", ".npmrc.example", ".pypirc.example",
}
_SENSITIVE_EXACT_NAMES = {
    ".npmrc", ".pypirc", ".netrc", ".git-credentials",
    "credentials", "credentials.json", "secrets", "secrets.json", "secret.json",
    "token", "token.json", "tokens.json", "auth.json", "client_secret.json",
    "service_account.json", "service_account_key.json",
    "application_default_credentials.json",
    "id_rsa", "id_ed25519", "id_ed25519_sk", "id_ecdsa", "id_dsa",
}
_SENSITIVE_SUFFIXES = (
    ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore",
    ".mobileprovision", ".tfstate", ".tfstate.backup",
)


def is_sensitive_file(path: Path | str) -> bool:
    """Identifica arquivos com alto risco de conter segredos. Templates são permitidos."""
    raw = str(path).replace("\\", "/")
    parts = tuple(part.strip().lower() for part in raw.split("/") if part.strip())
    name = parts[-1] if parts else ""
    if not name or name in _SAFE_SECRET_TEMPLATES:
        return False
    # Diretórios de credenciais são sensíveis por completo, mesmo quando seus
    # arquivos internos têm nomes genéricos (por exemplo, .kube/config).
    sensitive_dirs = {".ssh", ".aws", ".azure", ".kube", ".gnupg"}
    if any(part in sensitive_dirs for part in parts[:-1]):
        return True
    if ".docker" in parts[:-1] and name in {"config.json", ".config.json"}:
        return True
    if any(parts[i:i + 2] == (".config", "gcloud") for i in range(max(0, len(parts) - 1))):
        return True
    if "secrets" in parts[:-1] or "private" in parts[:-1]:
        return True
    if name.startswith(".env.") and name.endswith((".example", ".sample", ".template", ".dist")):
        return False

    # .env, .env.local, .env.production e variantes: preserva apenas templates explícitos.
    if name == ".env" or name.startswith(".env."):
        return True
    if name in _SENSITIVE_EXACT_NAMES:
        return True
    if name.endswith(_SENSITIVE_SUFFIXES):
        return True
    if name.startswith(("service-account", "firebase-adminsdk", "client_secret_")) and name.endswith(".json"):
        return True
    return False

SKIP_DIRS = {
    ".git",
    ".svn",
    ".hg",
    ".dart_tool",
    ".idea",
    ".vscode",
    ".vs",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".tox",
    ".eggs",
    "node_modules",
    "bower_components",
    "Pods",
    "DerivedData",
    "build",
    "dist",
    "out",
    "target",
    ".gradle",
    ".next",
    ".nuxt",
    ".svelte-kit",
    "coverage",
    ".nyc_output",
    "vendor",
    "venv",
    ".venv",
    "env",
    ".env",  # dir
    "android/.gradle",
    "ios/Pods",
    "windows/flutter",
    "linux/flutter",
    "macos/Flutter",
}

# nomes de arquivo/dir que NUNCA devem ser pulados só por estarem em lista genérica
IMPORTANT_NAMES = {
    "pubspec.yaml",
    "pubspec.lock",
    "package.json",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "requirements.txt",
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "cargo.toml",
    "cargo.lock",
    "go.mod",
    "go.sum",
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "androidmanifest.xml",
    "info.plist",
    "dockerfile",
    "docker-compose.yml",
    "docker-compose.yaml",
    "makefile",
    "cmakelists.txt",
    "readme.md",
    "readme",
    "license",
    "license.md",
    ".env.example",
    ".env.sample",
    "tsconfig.json",
    "jsconfig.json",
    "analysis_options.yaml",
    "main.dart",
    "main.py",
    "app.py",
    "index.ts",
    "index.js",
    "main.go",
    "main.rs",
}

KEEP_LOCK_NAMES = {
    "pubspec.lock",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "cargo.lock",
    "go.sum",
    "poetry.lock",
}

SKIP_FILE_SUFFIXES = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".ico",
    ".bmp",
    ".svg",  # opcional; às vezes útil
    ".mp3",
    ".mp4",
    ".wav",
    ".ogg",
    ".webm",
    ".apk",
    ".aab",
    ".ipa",
    ".exe",
    ".dll",
    ".so",
    ".dylib",
    ".o",
    ".a",
    ".class",
    ".jar",
    ".war",
    ".pyc",
    ".pyo",
    ".wasm",
    ".bin",
    ".dat",
    ".db",
    ".sqlite",
    ".sqlite3",
    ".ttf",
    ".otf",
    ".woff",
    ".woff2",
    ".eot",
    ".zip",
    ".tar",
    ".gz",
    ".7z",
    ".rar",
    ".pdf",  # PDFs entram por outro caminho (pdf_reader)
    ".lock",  # genérico; locks importantes estão em KEEP
}

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
    ".go",
    ".rs",
    ".swift",
    ".cs",
    ".rb",
    ".php",
    ".c",
    ".cpp",
    ".cc",
    ".h",
    ".hpp",
    ".m",
    ".mm",
    ".scala",
    ".groovy",
    ".lua",
    ".r",
    ".sql",
    ".sh",
    ".bash",
    ".zsh",
    ".ps1",
    ".bat",
    ".cmd",
    ".yaml",
    ".yml",
    ".json",
    ".toml",
    ".ini",
    ".cfg",
    ".conf",
    ".xml",
    ".html",
    ".htm",
    ".css",
    ".scss",
    ".sass",
    ".less",
    ".md",
    ".mdx",
    ".rst",
    ".txt",
    ".csv",
    ".tsv",
    ".gradle",
    ".properties",
    ".env",
    ".gitignore",
    ".dockerignore",
    ".editorconfig",
    ".plist",
}


def should_skip_dir(name: str) -> bool:
    n = name.lower().strip()
    if n in SKIP_DIRS:
        return True
    if n.startswith(".") and n not in {".github", ".vscode"}:
        # .github é útil (workflows); outros dot-dirs costumam ser junk
        if n in {".github"}:
            return False
        return True
    return False


def should_skip_file(path: Path) -> bool:
    name = path.name
    lower = name.lower()
    suffix = path.suffix.lower()

    if is_sensitive_file(path):
        return True

    if lower in KEEP_LOCK_NAMES or lower in IMPORTANT_NAMES:
        return False

    if suffix in SKIP_FILE_SUFFIXES and lower not in KEEP_LOCK_NAMES:
        return True

    # generated dart — mantém (modelos freezed/json_serializable às vezes importam)
    if lower.endswith(".g.dart") or lower.endswith(".freezed.dart"):
        return False

    if suffix and suffix not in TEXT_SUFFIXES and lower not in {
        n.lower() for n in IMPORTANT_NAMES
    }:
        if suffix in {"", ".log", ".map"}:
            return True
        if suffix not in TEXT_SUFFIXES:
            return True

    return False


def is_important(path: Path) -> bool:
    lower = path.name.lower()
    if lower in IMPORTANT_NAMES:
        return True
    return path.suffix.lower() in {
        ".dart",
        ".py",
        ".ts",
        ".tsx",
        ".js",
        ".jsx",
        ".java",
        ".kt",
        ".go",
        ".rs",
        ".swift",
        ".cs",
    }
