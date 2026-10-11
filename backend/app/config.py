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

    # Geração de imagens (OpenRouter Image API)
    IMAGE_GEN_MODEL = os.getenv(
        "IMAGE_GEN_MODEL",
        "openai/gpt-image-2.5-sunburst",
    ).strip()
    IMAGE_GEN_ENABLED = env_bool("IMAGE_GEN_ENABLED", True)

    # Limite de tokens de SAÍDA (evita OpenRouter 402 reservando 65k)
    MAX_OUTPUT_TOKENS = int(os.getenv("MAX_OUTPUT_TOKENS", "4096"))

    # ── LLM ───────────────────────────────────────────────────────────
    TEMPERATURE = float(os.getenv("LLM_TEMPERATURE", "0.6"))
    LLM_RETRIES = max(0, min(int(os.getenv("LLM_RETRIES", "3")), 6))

    # ── Agente com ferramentas (o MODELO decide quando buscar na web etc.) ──
    # Só vale para OpenRouter. Se o modelo não suportar tools, cai no modo antigo.
    AGENT_TOOLS_ENABLED = env_bool("AGENT_TOOLS_ENABLED", True)
    MAX_TOOL_ROUNDS = max(1, min(int(os.getenv("MAX_TOOL_ROUNDS", "4")), 8))
    MAX_TOOL_CALLS = max(1, min(int(os.getenv("MAX_TOOL_CALLS", "6")), 20))

    # ── Segurança ─────────────────────────────────────────────────────
    # Chave do app (enviada em X-API-Key). Sem ela configurada, a API fica aberta
    # (compatibilidade) e um aviso aparece no log. Em produção: defina SEMPRE.
    GAMA_API_KEY = os.getenv("GAMA_API_KEY", "").strip()
    REQUIRE_API_KEY = env_bool("GAMA_REQUIRE_API_KEY", False)
    CORS_ORIGINS = [o.strip() for o in os.getenv("CORS_ORIGINS", "*").split(",") if o.strip()]
    RATE_LIMIT_CHAT_PER_MIN = int(os.getenv("RATE_LIMIT_CHAT_PER_MIN", "20"))
    RATE_LIMIT_DEFAULT_PER_MIN = int(os.getenv("RATE_LIMIT_DEFAULT_PER_MIN", "120"))
    # Quantos proxies confiáveis existem na frente (Railway/Render = 1).
    TRUSTED_PROXY_HOPS = max(0, int(os.getenv("TRUSTED_PROXY_HOPS", "1")))
    MAX_BODY_MB = int(os.getenv("MAX_BODY_MB", "60"))
    MAX_CHAT_MESSAGES = int(os.getenv("MAX_CHAT_MESSAGES", "120"))
    MAX_IMAGES = int(os.getenv("MAX_IMAGES", "4"))
    MAX_IMAGE_B64_CHARS = int(os.getenv("MAX_IMAGE_B64_CHARS", str(14_000_000)))
    HEALTH_CACHE_SECONDS = int(os.getenv("HEALTH_CACHE_SECONDS", "30"))

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
