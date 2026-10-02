import os


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


class Settings:
    HOST = os.getenv("FREQUENCIA40_HOST", "0.0.0.0")
    PORT = int(os.getenv("PORT", os.getenv("FREQUENCIA40_PORT", "8000")))

    # O backend usa o serviço Ollama no Railway.
    PROVIDER = os.getenv("LLM_PROVIDER", "ollama").strip().lower()

    if PROVIDER != "ollama":
        raise ValueError(
            f"LLM_PROVIDER inválido: {PROVIDER!r}. "
            "Use LLM_PROVIDER=ollama."
        )

    OLLAMA_URL = os.getenv(
        "OLLAMA_URL",
        "http://ollama.railway.internal:11434",
    ).strip().rstrip("/")

    if not OLLAMA_URL:
        raise ValueError("OLLAMA_URL não pode ficar vazio.")

    OLLAMA_DEFAULT_MODEL = os.getenv(
        "OLLAMA_DEFAULT_MODEL",
        "qwen2.5-coder:7b",
    ).strip()

    OLLAMA_MODELS = [
        model.strip()
        for model in os.getenv(
            "OLLAMA_MODELS",
            OLLAMA_DEFAULT_MODEL,
        ).split(",")
        if model.strip()
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

    VISION_MODEL = os.getenv("VISION_MODEL", "").strip()


settings = Settings()