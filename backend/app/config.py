import os


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


class Settings:
    HOST = os.getenv("FREQUENCIA40_HOST", "0.0.0.0")
    PORT = int(os.getenv("PORT", os.getenv("FREQUENCIA40_PORT", "8000")))

    # Produção: Groq (rápido). Ollama só se LLM_PROVIDER=ollama.
    PROVIDER = os.getenv("LLM_PROVIDER", "groq").strip().lower()

    if PROVIDER not in {"groq", "ollama"}:
        raise ValueError(
            f"LLM_PROVIDER inválido: {PROVIDER!r}. Use groq ou ollama."
        )

    # ── Groq (OpenAI-compatible) ─────────────────────────────────────
    GROQ_API_KEY = os.getenv("GROQ_API_KEY", "").strip()
    GROQ_BASE_URL = os.getenv(
        "GROQ_BASE_URL",
        "https://api.groq.com/openai/v1",
    ).strip().rstrip("/")

    # llama-3.3-70b: forte em código e ainda rápido no Groq
    # llama-3.1-8b-instant: máximo de velocidade
    GROQ_DEFAULT_MODEL = os.getenv(
        "GROQ_DEFAULT_MODEL",
        "llama-3.3-70b-versatile",
    ).strip()

    GROQ_MODELS = [
        m.strip()
        for m in os.getenv(
            "GROQ_MODELS",
            "llama-3.3-70b-versatile,llama-3.1-8b-instant",
        ).split(",")
        if m.strip()
    ]

    # ── Ollama (opcional / legado) ───────────────────────────────────
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

    if PROVIDER == "groq" and not GROQ_API_KEY:
        # não quebra o boot; health fica offline até configurar a chave
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

    VISION_MODEL = os.getenv("VISION_MODEL", "").strip()

    @property
    def default_model(self) -> str:
        if self.PROVIDER == "groq":
            return self.GROQ_DEFAULT_MODEL
        return self.OLLAMA_DEFAULT_MODEL

    @property
    def allowed_models(self) -> list[str]:
        if self.PROVIDER == "groq":
            return list(self.GROQ_MODELS)
        return list(self.OLLAMA_MODELS)


settings = Settings()
