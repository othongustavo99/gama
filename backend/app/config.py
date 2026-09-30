import os


class Settings:
    HOST = os.getenv("FREQUENCIA40_HOST", "0.0.0.0")
    PORT = int(os.getenv("FREQUENCIA40_PORT", "8000"))

    PROVIDER = os.getenv("LLM_PROVIDER", "ollama").strip().lower()

    OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")

    OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
    OPENROUTER_BASE_URL = os.getenv(
        "OPENROUTER_BASE_URL",
        "https://openrouter.ai/api/v1",
    )
    OPENROUTER_DEFAULT_MODEL = os.getenv(
        "OPENROUTER_DEFAULT_MODEL",
        "openai/gpt-4o-mini",
    )

    GROQ_API_KEY = os.getenv("GROQ_API_KEY", "")
    GROQ_BASE_URL = os.getenv(
        "GROQ_BASE_URL",
        "https://api.groq.com/openai/v1",
    )
    GROQ_DEFAULT_MODEL = os.getenv(
        "GROQ_DEFAULT_MODEL",
        "llama-3.3-70b-versatile",
    )

    DATA_DIR = os.getenv("DATA_DIR", "")

    APP_URL = os.getenv("APP_URL", "https://frequencia40.local")
    APP_NAME = os.getenv("APP_NAME", "Frequencia40-Gamma")

    # --- Web search ---
    WEB_SEARCH_ENABLED = os.getenv("WEB_SEARCH_ENABLED", "1").strip() not in (
        "0",
        "false",
        "False",
        "no",
    )
    WEB_SEARCH_TIMEOUT = float(os.getenv("WEB_SEARCH_TIMEOUT", "12"))

    # Opcionais (melhoram muito a qualidade se configurados)
    BRAVE_API_KEY = os.getenv("BRAVE_API_KEY", "").strip()
    SERPER_API_KEY = os.getenv("SERPER_API_KEY", "").strip()  # Google via Serper
    TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "").strip()


settings = Settings()
