import os


class Settings:
    HOST = os.getenv("FREQUENCIA40_HOST", "0.0.0.0")
    PORT = int(os.getenv("FREQUENCIA40_PORT", "8000"))

    # ollama | openrouter | groq
    PROVIDER = os.getenv("LLM_PROVIDER", "ollama").strip().lower()

    # --- Ollama (local) ---
    OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")

    # --- OpenRouter ---
    OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
    OPENROUTER_BASE_URL = os.getenv(
        "OPENROUTER_BASE_URL",
        "https://openrouter.ai/api/v1",
    )
    OPENROUTER_DEFAULT_MODEL = os.getenv(
        "OPENROUTER_DEFAULT_MODEL",
        "openai/gpt-4o-mini",
    )

    # --- Groq ---
    GROQ_API_KEY = os.getenv("GROQ_API_KEY", "")
    GROQ_BASE_URL = os.getenv(
        "GROQ_BASE_URL",
        "https://api.groq.com/openai/v1",
    )
    GROQ_DEFAULT_MODEL = os.getenv(
        "GROQ_DEFAULT_MODEL",
        "llama-3.3-70b-versatile",
    )

    # Memória em disco (no deploy use volume ou /tmp)
    DATA_DIR = os.getenv("DATA_DIR", "")

    # Opcional: identifica o app no OpenRouter
    APP_URL = os.getenv("APP_URL", "https://frequencia40.local")
    APP_NAME = os.getenv("APP_NAME", "Frequencia40-Gamma")

    # --- Web search ---
    # 1 = ligado (padrão), 0 = desliga busca automática
    WEB_SEARCH_ENABLED = os.getenv("WEB_SEARCH_ENABLED", "1").strip() not in (
        "0",
        "false",
        "False",
        "no",
    )
    # Opcional: https://brave.com/search/api/
    BRAVE_API_KEY = os.getenv("BRAVE_API_KEY", "").strip()


settings = Settings()
