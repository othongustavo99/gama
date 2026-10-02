import os


class Settings:
    HOST = os.getenv("FREQUENCIA40_HOST", "0.0.0.0")
    PORT = int(os.getenv("FREQUENCIA40_PORT", "8000"))

    # O Gama usa Ollama no servidor, nunca o Ollama do PC do usuário.
    PROVIDER = "ollama"
    OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434").rstrip("/")

    # Modelo principal: escolhido para caber confortavelmente em servidores
    # de 8–16 GB de RAM quando usado em quantização Q4_K_M.
    OLLAMA_DEFAULT_MODEL = os.getenv(
        "OLLAMA_DEFAULT_MODEL", "qwen2.5-coder:7b"
    ).strip()

    # Por padrão só expomos o modelo principal. Para adicionar outro modelo,
    # use OLLAMA_MODELS="qwen2.5-coder:7b,outro-modelo".
    OLLAMA_MODELS = [
        model.strip()
        for model in os.getenv(
            "OLLAMA_MODELS", "qwen2.5-coder:7b"
        ).split(",")
        if model.strip()
    ]

    DATA_DIR = os.getenv("DATA_DIR", "/data")
    APP_URL = os.getenv("APP_URL", "")
    APP_NAME = os.getenv("APP_NAME", "Frequencia40-Gamma")

    WEB_SEARCH_ENABLED = os.getenv("WEB_SEARCH_ENABLED", "1").strip().lower() not in (
        "0", "false", "no"
    )
    WEB_SEARCH_TIMEOUT = float(os.getenv("WEB_SEARCH_TIMEOUT", "12"))
    WEB_SEARCH_MODE = os.getenv("WEB_SEARCH_MODE", "aggressive").strip().lower()

    BRAVE_API_KEY = os.getenv("BRAVE_API_KEY", "").strip()
    SERPER_API_KEY = os.getenv("SERPER_API_KEY", "").strip()
    TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "").strip()

    # O Qwen2.5-Coder 7B é um modelo de texto/código. Não tentamos mandar
    # imagens diretamente para ele.
    VISION_MODEL = os.getenv("VISION_MODEL", "").strip()


settings = Settings()
