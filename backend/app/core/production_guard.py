"""Preflight explícito para evitar deploy comercial sem autenticação.

Não altera o modo de desenvolvimento: habilite GAMA_PRODUCTION_MODE=1 no
Railway quando a integração OAuth estiver configurada e validada.
"""

from __future__ import annotations

import os


_TRUE = {"1", "true", "yes", "on"}


def _enabled(env: dict[str, str], key: str, *, default: str = "0") -> bool:
    return str(env.get(key, default)).strip().lower() in _TRUE


def production_configuration_errors(env: dict[str, str]) -> list[str]:
    """Retorna erros operacionais sem incluir valores de credenciais no log."""
    if not _enabled(env, "GAMA_PRODUCTION_MODE"):
        return []

    errors: list[str] = []
    if not _enabled(env, "GAMA_REQUIRE_AUTH", default="1"):
        errors.append("GAMA_REQUIRE_AUTH deve ser 1 em produção")
    audiences = [v.strip() for v in env.get("GOOGLE_OAUTH_CLIENT_IDS", "").split(",") if v.strip()]
    if not audiences or any(not v.endswith(".apps.googleusercontent.com") for v in audiences):
        errors.append("GOOGLE_OAUTH_CLIENT_IDS deve conter OAuth client IDs válidos")
    if _enabled(env, "GAMA_REQUIRE_API_KEY") and not env.get("GAMA_API_KEY", "").strip():
        errors.append("GAMA_REQUIRE_API_KEY exige GAMA_API_KEY configurada")
    if env.get("LLM_PROVIDER", "openrouter").strip().lower() == "openrouter" and not env.get("OPENROUTER_API_KEY", "").strip():
        errors.append("OPENROUTER_API_KEY deve estar configurada em produção")
    return errors


def assert_safe_production_configuration() -> None:
    problems = production_configuration_errors(dict(os.environ))
    if problems:
        raise RuntimeError("Configuração comercial insegura: " + "; ".join(problems))
