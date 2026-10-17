#!/usr/bin/env python3
"""Patch seguro para ligar a geração de vídeos ao endpoint /chat da Gama.

Execute na raiz do repositório. Faz cópias .bak dos arquivos e só grava se
as âncoras esperadas existirem exatamente uma vez e o Python continuar válido.
"""
from __future__ import annotations

from datetime import datetime
from pathlib import Path
import sys

CHAT_REL = Path("backend/app/routes/chat.py")
ARTIFACTS_REL = Path("backend/app/routes/artifacts.py")

IMPORT_ANCHOR = "from ..core.identity import current_user_id\n"
VIDEO_IMPORT = '''from ..core.video_gen import (
    VideoIntent,
    build_video_prompt,
    detect_video_intent,
    generate_video_events,
    parse_video_options,
)
from ..core.document_builder.store import save_artifact
'''

IMAGE_DETECTION_ANCHOR = '''    want_image_gen = bool(
        getattr(app_settings, "IMAGE_GEN_ENABLED", True)
        and last_user
        and image_req is not None
        and image_req.intent in (ImageIntent.GENERATE, ImageIntent.EDIT, ImageIntent.IMPROVE)
    )
'''
VIDEO_DETECTION = '''
    # Video Generator: o módulo já existia, mas não era acionado pela rota /chat.
    # Só intercepta pedidos explícitos de criação/animação, sem desviar análise comum.
    video_req = detect_video_intent(
        last_user,
        has_attached_images=has_imgs,
    ) if last_user else None
    want_video_gen = bool(
        video_req is not None
        and video_req.intent in (VideoIntent.CREATE, VideoIntent.ANIMATE)
    )
'''

VIDEO_BRANCH = r'''            # --- Video Generator: criação de vídeo por texto ou animação de imagem ---
            if want_video_gen and video_req is not None:
                if not bool(plugin_flags.get("video_gen", True)):
                    reply = "A geração de vídeo está desativada em Plugins. Ative-a e tente novamente."
                    yield json.dumps({"message": {"role": "assistant", "content": reply}, "done": False}, ensure_ascii=False) + "\n"
                    yield json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}, ensure_ascii=False) + "\n"
                    return
                if not getattr(app_settings, "VIDEO_GEN_ENABLED", True):
                    reply = "A geração de vídeo está desativada no backend. Configure VIDEO_GEN_ENABLED=true no Railway."
                    yield json.dumps({"message": {"role": "assistant", "content": reply}, "done": False}, ensure_ascii=False) + "\n"
                    yield json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}, ensure_ascii=False) + "\n"
                    return
                video_intent = video_req.intent
                video_prompt = build_video_prompt(last_user, intent=video_intent)
                video_options = parse_video_options(last_user)
                reference_images = []
                if video_intent == VideoIntent.ANIMATE:
                    for image in (request.images or []):
                        image_data = getattr(image, "data", None)
                        if image_data:
                            reference_images.append({
                                "mime": (
                                    getattr(image, "mime", None)
                                    or getattr(image, "mime_type", None)
                                    or "image/jpeg"
                                ),
                                "data": image_data,
                            })
                generated_artifact = None
                generation_error = None
                try:
                    async for video_event in generate_video_events(
                        video_prompt,
                        duration=video_options["duration"],
                        resolution=video_options["resolution"],
                        aspect_ratio=video_options["aspect_ratio"],
                        reference_images=(reference_images if reference_images else None),
                        generate_audio=video_options["generate_audio"],
                    ):
                        event_type = video_event.get("type")
                        if event_type == "phase":
                            phase = str(video_event.get("phase") or "video_generating")
                            yield json.dumps({"gama_meta": {"phase": phase}}, ensure_ascii=False) + "\n"
                        elif event_type == "error":
                            generation_error = str(video_event.get("error") or "O provedor não conseguiu gerar o vídeo.")[:600]
                        elif event_type == "completed":
                            video_bytes = video_event.get("data")
                            if not isinstance(video_bytes, bytes) or not video_bytes:
                                generation_error = "O provedor não retornou um arquivo de vídeo válido."
                                continue
                            try:
                                stored = save_artifact(
                                    kind="video",
                                    filename="gama_video_gerado.mp4",
                                    data=video_bytes,
                                    user_id=user_id,
                                    meta={
                                        "duration_seconds": video_options["duration"],
                                        "resolution": video_options["resolution"],
                                        "aspect_ratio": video_options["aspect_ratio"],
                                        "audio_generated": video_options["generate_audio"],
                                        "provider_cost_usd": video_event.get("cost"),
                                        "model": video_event.get("model"),
                                    },
                                )
                                generated_artifact = {
                                    "artifact_id": stored.get("artifact_id"),
                                    "filename": stored.get("filename", "gama_video_gerado.mp4"),
                                    "kind": "video",
                                    "size": stored.get("size", len(video_bytes)),
                                    "duration_seconds": video_options["duration"],
                                    "resolution": video_options["resolution"],
                                    "aspect_ratio": video_options["aspect_ratio"],
                                    "audio_generated": video_options["generate_audio"],
                                    "provider_cost_usd": video_event.get("cost"),
                                    "model": video_event.get("model"),
                                }
                                yield json.dumps(
                                    {"gama_meta": {"phase": "artifact_ready", "artifact": generated_artifact}},
                                    ensure_ascii=False,
                                ) + "\n"
                            except Exception:
                                logger.exception("Could not save generated video artifact")
                                generation_error = (
                                    "O vídeo foi gerado, mas não consegui salvá-lo na Biblioteca. "
                                    "Verifique o espaço disponível no armazenamento do Railway."
                                )
                except Exception:
                    logger.exception("Video generation flow failed")
                    generation_error = "Falha inesperada ao gerar o vídeo. Tente novamente."
                if generated_artifact:
                    reply = (
                        "Vídeo gerado com sucesso. O arquivo está disponível no cartão abaixo "
                        "e também pode ser salvo na Biblioteca."
                    )
                else:
                    reply = "Não consegui gerar o vídeo. " + (
                        generation_error or "O serviço de vídeo não retornou um resultado válido."
                    )
                yield json.dumps({"message": {"role": "assistant", "content": reply}, "done": False}, ensure_ascii=False) + "\n"
                yield json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}, ensure_ascii=False) + "\n"
                return
'''

ARTIFACT_MEDIA_ANCHOR = '''    media = {
        "zip": "application/zip",
        "pdf": "application/pdf",
    }.get(info.get("kind", ""), "application/octet-stream")
'''
ARTIFACT_MEDIA_REPLACEMENT = '''    media = {
        "zip": "application/zip",
        "pdf": "application/pdf",
        "video": "video/mp4",
    }.get(info.get("kind", ""), "application/octet-stream")
'''


def fail(message: str) -> None:
    print(f"ERRO: {message}", file=sys.stderr)
    raise SystemExit(1)


def replace_once(source: str, anchor: str, replacement: str, label: str) -> str:
    count = source.count(anchor)
    if count != 1:
        fail(
            f"não encontrei exatamente uma ocorrência do trecho esperado em {label} "
            f"(encontrei {count}). Nenhum arquivo foi alterado."
        )
    return source.replace(anchor, replacement, 1)


VIDEO_GEN_REL = Path("backend/app/core/video_gen.py")
VIDEO_API_FIX_MARKER = 'polling_url = urljoin(base.rstrip("/") + "/", raw_polling_url)'

VIDEO_JOB_ID_ANCHOR = '''            if not re.fullmatch(r"[A-Za-z0-9_-]{4,128}", job_id):
                yield {"type": "error", "error": "O provedor não retornou um identificador válido para o vídeo."}
                return
            yield {"type": "phase", "phase": "video_generating"}
'''

VIDEO_JOB_ID_REPLACEMENT = '''            if not re.fullmatch(r"[A-Za-z0-9_-]{4,128}", job_id):
                yield {"type": "error", "error": "O provedor não retornou um identificador válido para o vídeo."}
                return
            # Use the polling_url oficial retornado pela OpenRouter. Aceita caminho
            # relativo ou URL absoluta, mas não permite polling em outro host.
            raw_polling_url = str(job.get("polling_url") or f"{base}/videos/{job_id}").strip()
            polling_url = urljoin(base.rstrip("/") + "/", raw_polling_url)
            base_parts = urlparse(base)
            polling_parts = urlparse(polling_url)
            if (
                polling_parts.scheme != base_parts.scheme
                or polling_parts.netloc != base_parts.netloc
                or not polling_parts.path.startswith(base_parts.path.rstrip("/") + "/videos/")
            ):
                yield {"type": "error", "error": "O provedor retornou uma URL de acompanhamento inválida."}
                return
            yield {"type": "phase", "phase": "video_generating"}
'''

OLD_POLL_CALL = '                status_response = await client.get(f"{base}/videos/{job_id}", headers=headers)\n'
NEW_POLL_CALL = '                status_response = await client.get(polling_url, headers=headers)\n'

OLD_VIDEO_DOWNLOAD = '''            yield {"type": "phase", "phase": "video_downloading"}
            content = await client.get(f"{base}/videos/{job_id}/content?index=0", headers=headers)
            if content.status_code >= 400:
                yield {"type": "error", "error": f"O vídeo foi gerado, mas não consegui baixá-lo do provedor (HTTP {content.status_code})."}
                return
            data = content.content
'''

NEW_VIDEO_DOWNLOAD = '''            yield {"type": "phase", "phase": "video_downloading"}
            # A API documentada devolve os links do arquivo em unsigned_urls.
            # Não envie os headers da OpenRouter para o host de armazenamento.
            raw_video_urls = latest.get("unsigned_urls")
            if isinstance(raw_video_urls, str):
                raw_video_urls = [raw_video_urls]
            video_url = next(
                (
                    value.strip()
                    for value in (raw_video_urls if isinstance(raw_video_urls, list) else [])
                    if isinstance(value, str) and value.strip()
                ),
                "",
            )
            if not video_url:
                yield {"type": "error", "error": "O provedor concluiu a geração, mas não retornou uma URL para baixar o vídeo."}
                return
            video_parts = urlparse(video_url)
            if video_parts.scheme != "https" or not video_parts.netloc:
                yield {"type": "error", "error": "O provedor retornou uma URL de vídeo inválida."}
                return
            # unsigned_urls da OpenRouter ainda exigem Bearer quando o link
            # aponta para openrouter.ai; URLs de storage externo podem ser públicas.
            # Nunca encaminhe a chave da OpenRouter para um host externo.
            auth_headers = headers if video_parts.netloc.lower() == urlparse(base).netloc.lower() else None
            content = await client.get(video_url, headers=auth_headers)
            if content.status_code >= 400:
                yield {"type": "error", "error": f"O vídeo foi gerado, mas não consegui baixá-lo do provedor de arquivos (HTTP {content.status_code})."}
                return
            data = content.content
'''


def patch_video_gen(source: str) -> str:
    """Patch OpenRouter poll/download to match the documented video API."""
    # Se o patch anterior já estiver instalado, atualize apenas a chamada de
    # download que causava HTTP 401 no endpoint autenticado da OpenRouter.
    if VIDEO_API_FIX_MARKER in source and 'latest.get("unsigned_urls")' in source:
        old_download_call = '            content = await client.get(video_url)\n'
        new_download_call = '            auth_headers = headers if video_parts.netloc.lower() == urlparse(base).netloc.lower() else None\n            content = await client.get(video_url, headers=auth_headers)\n'
        if new_download_call in source:
            return source
        if old_download_call in source:
            return source.replace(old_download_call, new_download_call, 1)
        fail("o downloader de vídeo já está parcialmente alterado; nenhum arquivo foi modificado.")
    if 'latest.get("unsigned_urls")' in source or VIDEO_API_FIX_MARKER in source:
        fail("backend/app/core/video_gen.py contém uma correção parcial; revise o arquivo antes de aplicar.")
    typing_anchor = "from typing import Any, AsyncIterator, Optional\n"
    if "from urllib.parse import urljoin, urlparse\n" not in source:
        source = replace_once(
            source,
            typing_anchor,
            typing_anchor + "from urllib.parse import urljoin, urlparse\n",
            str(VIDEO_GEN_REL),
        )
    source = replace_once(
        source,
        VIDEO_JOB_ID_ANCHOR,
        VIDEO_JOB_ID_REPLACEMENT,
        str(VIDEO_GEN_REL),
    )
    source = replace_once(source, OLD_POLL_CALL, NEW_POLL_CALL, str(VIDEO_GEN_REL))
    source = replace_once(source, OLD_VIDEO_DOWNLOAD, NEW_VIDEO_DOWNLOAD, str(VIDEO_GEN_REL))
    return source


def main() -> None:
    root = Path.cwd()
    chat_path = root / CHAT_REL
    artifacts_path = root / ARTIFACTS_REL
    video_path = root / VIDEO_GEN_REL
    for path in (chat_path, artifacts_path, video_path):
        if not path.is_file():
            fail(f"arquivo não encontrado: {path.relative_to(root) if path.is_relative_to(root) else path}. Execute na raiz do repositório Gama.")

    originals = {
        chat_path: chat_path.read_text(encoding="utf-8"),
        artifacts_path: artifacts_path.read_text(encoding="utf-8"),
        video_path: video_path.read_text(encoding="utf-8"),
    }
    updated = dict(originals)

    # Integra o gerador ao chat somente nos pontos que ainda faltam.
    chat = updated[chat_path]
    if "from ..core.video_gen import (" not in chat:
        chat = replace_once(chat, IMPORT_ANCHOR, IMPORT_ANCHOR + VIDEO_IMPORT, str(CHAT_REL))
    if "video_req = detect_video_intent(" not in chat:
        chat = replace_once(chat, IMAGE_DETECTION_ANCHOR, IMAGE_DETECTION_ANCHOR + VIDEO_DETECTION, str(CHAT_REL))
    if "# --- Video Generator: criação de vídeo por texto ou animação de imagem ---" not in chat:
        branch_anchor = "            # --- fase: geração de imagem (quando o usuário pede para criar/imaginar) ---\n"
        chat = replace_once(chat, branch_anchor, VIDEO_BRANCH + branch_anchor, str(CHAT_REL))
    updated[chat_path] = chat

    artifacts = updated[artifacts_path]
    if '"video": "video/mp4"' not in artifacts:
        artifacts = replace_once(artifacts, ARTIFACT_MEDIA_ANCHOR, ARTIFACT_MEDIA_REPLACEMENT, str(ARTIFACTS_REL))
    updated[artifacts_path] = artifacts
    updated[video_path] = patch_video_gen(updated[video_path])

    # Valida todos os arquivos antes de gravar qualquer um.
    try:
        for path, content in updated.items():
            compile(content, str(path), "exec")
    except SyntaxError as exc:
        fail(f"a validação de sintaxe falhou em {exc.filename}:{exc.lineno}: {exc.msg}. Nenhum arquivo foi alterado.")

    changed = [path for path in originals if updated[path] != originals[path]]
    if not changed:
        print("A correção de geração de vídeo já está aplicada. Nenhum arquivo foi alterado.")
        return

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backups = []
    for path in changed:
        backup = path.with_name(f"{path.name}.bak_video_{stamp}")
        backup.write_text(originals[path], encoding="utf-8")
        backups.append(backup)
    try:
        for path in changed:
            path.write_text(updated[path], encoding="utf-8", newline="\n")
    except Exception:
        # Roll back source files if a disk write fails mid-application.
        for path in changed:
            path.write_text(originals[path], encoding="utf-8", newline="\n")
        fail("falha ao gravar os arquivos; restaurei os originais. Nenhuma correção foi mantida.")

    print("Correção aplicada e sintaxe Python validada.")
    for path in changed:
        print(f"Alterado: {path.relative_to(root)}")
    for backup in backups:
        print(f"Backup:   {backup.relative_to(root)}")
    print("Agora revise com git diff --check e git diff; depois faça commit/push para o Railway.")


if __name__ == "__main__":
    main()
