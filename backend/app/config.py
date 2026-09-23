import os


class Settings:
    HOST = os.getenv(
        "FREQUENCIA40_HOST",
        "0.0.0.0",
    )

    PORT = int(
        os.getenv(
            "FREQUENCIA40_PORT",
            "8000",
        )
    )

    OLLAMA_URL = os.getenv(
        "OLLAMA_URL",
        "http://127.0.0.1:11434",
    )


settings = Settings()