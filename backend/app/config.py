import os


class Settings:
    HOST = os.getenv("FREQUENCIA40_HOST", "0.0.0.0")
    PORT = int(os.getenv("FREQUENCIA40_PORT", "8000"))

    # Provider único da Gama
    PROVIDER = os.getenv("LLM_PROVIDER", "ollama").strip().lower()

    # Ollama no Railway
    OLLAMA_URL = os.getenv(
        "OLLAMA_URL",
        "http://ollama.railway.internal:11434",
    )

    # Modelo principal
    OLLAMA_DEFAULT_MODEL = os.getenv(
        "OLLAMA_DEFAULT_MODEL",
        "qwen2.5-coder:14b",
    )

    # Modelos disponíveis na Gama
    OLLAMA_MODELS = [
        "qwen2.5-coder:14b",
        "phi4-mini",
    ]

    DATA_DIR = os.getenv("DATA_DIR", "")

    APP_URL = os.getenv(
        "APP_URL",
        "https://frequencia40.local",
    )

    APP_NAME = os.getenv(
        "APP_NAME",
        "Frequencia40-Gamma",
    )

    WEB_SEARCH_ENABLED = os.getenv(
        "WEB_SEARCH_ENABLED",
        "1",
    ).strip() not in (
        "0",
        "false",
        "False",
        "no",
    )

    WEB_SEARCH_TIMEOUT = float(
        os.getenv("WEB_SEARCH_TIMEOUT", "12")
    )

    WEB_SEARCH_MODE = os.getenv(
        "WEB_SEARCH_MODE",
        "aggressive",
    ).strip().lower()

    BRAVE_API_KEY = os.getenv(
        "BRAVE_API_KEY",
        "",
    ).strip()

    SERPER_API_KEY = os.getenv(
        "SERPER_API_KEY",
        "",
    ).strip()

    TAVILY_API_KEY = os.getenv(
        "TAVILY_API_KEY",
        "",
    ).strip()

    VISION_MODEL = os.getenv(
        "VISION_MODEL",
        "",
    )


settings = Settings()