"""Configuração do backend Gama — provedor: OpenRouter (padrão) ou Ollama (legado/local)."""

from __future__ import annotations

import os


def env_bool(name: str, default: bool = False) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return v.strip().lower() in {"1", "true", "yes", "on"}


class Settings:
    HOST = os.getenv("FREQUENCIA40_HOST", "0.0.0.0")
    PORT = int(os.getenv("PORT", os.getenv("FREQUENCIA40_PORT", "8000")))

    # Produção: OpenRouter. Ollama só se LLM_PROVIDER=ollama.
    PROVIDER = os.getenv("LLM_PROVIDER", "openrouter").strip().lower()

    if PROVIDER not in {"openrouter", "ollama"}:
        raise ValueError(
            f"LLM_PROVIDER inválido: {PROVIDER!r}. Use openrouter ou ollama."
        )

    # ── OpenRouter (OpenAI-compatible) ────────────────────────────────
    OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "").strip()
    OPENROUTER_BASE_URL = os.getenv(
        "OPENROUTER_BASE_URL",
        "https://openrouter.ai/api/v1",
    ).strip().rstrip("/")
    OPENROUTER_HTTP_REFERER = os.getenv(
        "OPENROUTER_HTTP_REFERER",
        os.getenv("APP_URL", "https://gama.app"),
    ).strip()
    OPENROUTER_APP_TITLE = os.getenv(
        "OPENROUTER_APP_TITLE",
        os.getenv("APP_NAME", "Frequencia40-Gamma"),
    ).strip()

    # Modelo único padrão (GPT-5.4 Mini via OpenRouter)
    _DEFAULT_MODEL = "openai/gpt-5.4-mini"

    OPENROUTER_DEFAULT_MODEL = os.getenv(
        "OPENROUTER_DEFAULT_MODEL",
        _DEFAULT_MODEL,
    ).strip()

    # Uma única string no 2º arg do getenv (várias strings com vírgula quebravam)
    OPENROUTER_MODELS = [
        m.strip()
        for m in os.getenv("OPENROUTER_MODELS", _DEFAULT_MODEL).split(",")
        if m.strip()
    ]

    CONVERSATION_MODEL = os.getenv("CONVERSATION_MODEL", _DEFAULT_MODEL).strip()
    CODING_MODEL = os.getenv("CODING_MODEL", _DEFAULT_MODEL).strip()

    # ── Ollama (opcional / legado / local) ────────────────────────────
    OLLAMA_URL = os.getenv(
        "OLLAMA_URL",
        "http://127.0.0.1:11434",
    ).strip().rstrip("/")
    OLLAMA_KEEP_ALIVE = os.getenv("OLLAMA_KEEP_ALIVE", "24h").strip() or "24h"
    OLLAMA_DEFAULT_MODEL = os.getenv("OLLAMA_DEFAULT_MODEL", "qwen2.5:1.5b").strip()
    OLLAMA_MODELS = [
        m.strip()
        for m in os.getenv("OLLAMA_MODELS", OLLAMA_DEFAULT_MODEL).split(",")
        if m.strip()
    ]

    if PROVIDER == "openrouter" and not OPENROUTER_API_KEY:
        pass

    DATA_DIR = os.getenv("DATA_DIR", "/data")
    APP_URL = os.getenv("APP_URL", "")
    APP_NAME = os.getenv("APP_NAME", "Frequencia40-Gamma")

    WEB_SEARCH_ENABLED = env_bool("WEB_SEARCH_ENABLED", True)
    WEB_SEARCH_TIMEOUT = float(os.getenv("WEB_SEARCH_TIMEOUT", "12"))
    WEB_SEARCH_MODE = os.getenv("WEB_SEARCH_MODE", "balanced").strip().lower()

    BRAVE_API_KEY = os.getenv("BRAVE_API_KEY", "").strip()
    SERPER_API_KEY = os.getenv("SERPER_API_KEY", "").strip()
    TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "").strip()

    VISION_MODEL = os.getenv("VISION_MODEL", _DEFAULT_MODEL).strip()

    # Limite de tokens de SAÍDA (evita OpenRouter 402 reservando 65k)
    MAX_OUTPUT_TOKENS = int(os.getenv("MAX_OUTPUT_TOKENS", "4096"))

    @property
    def default_model(self) -> str:
        if self.PROVIDER == "openrouter":
            return self.OPENROUTER_DEFAULT_MODEL
        return self.OLLAMA_DEFAULT_MODEL

    @property
    def allowed_models(self) -> list[str]:
        if self.PROVIDER == "openrouter":
            models = list(self.OPENROUTER_MODELS)
            for extra in (
                self.CONVERSATION_MODEL,
                self.CODING_MODEL,
                self.VISION_MODEL,
                self.OPENROUTER_DEFAULT_MODEL,
            ):
                if extra and extra not in models:
                    models.append(extra)
            return models
        return list(self.OLLAMA_MODELS)


settings = Settings()
