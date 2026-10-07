"""Code Analyzer — skill da Gama para análise seletiva de código.

Absorve e evolui o Project Analyzer. Fontes suportadas:
  - ZIP de projeto
  - URL de repositório GitHub
  - PDF com código/documentação técnica
  - trechos de código enviados na conversa

Princípio: não cortar código à força; encontrar melhor o que precisa ser lido.
Três níveis: quick | targeted | deep.
"""

from .pipeline import (
    ingest_zip,
    ingest_github,
    ingest_pdf,
    ingest_direct_code,
    build_query_context,
    get_project_summary,
    detect_and_prepare,
)

__all__ = [
    "ingest_zip",
    "ingest_github",
    "ingest_pdf",
    "ingest_direct_code",
    "build_query_context",
    "get_project_summary",
    "detect_and_prepare",
]
