#!/usr/bin/env python3
# Aplica correções adicionais da Gama de forma conservadora, criando backup dos arquivos.
from __future__ import annotations

import datetime as _dt
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()


def read(rel: str) -> str:
    path = ROOT / rel
    if not path.is_file():
        raise RuntimeError(f"Arquivo não encontrado: {rel}. Execute este script na raiz do projeto Gama.")
    return path.read_text(encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"Não consegui localizar de forma única o trecho '{label}' (encontrei {count}). Nenhum arquivo foi alterado.")
    return text.replace(old, new, 1)


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        raise RuntimeError(f"Início do trecho '{label}' não encontrado. Nenhum arquivo foi alterado.")
    b = text.find(end, a + len(start))
    if b < 0:
        raise RuntimeError(f"Fim do trecho '{label}' não encontrado. Nenhum arquivo foi alterado.")
    return text[:a] + replacement + text[b:]


files: dict[str, str] = {}
for rel in [
    "pubspec.yaml",
    "lib/widgets/message_content.dart",
    "lib/screens/chat_screen.dart",
    "lib/models/message.dart",
    "lib/models/message.g.dart",
    "lib/services/conversation_sync_service.dart",
    "lib/services/conversation_service.dart",
    "backend/app/routes/conversations.py",
    "backend/app/core/conversations.py",
]:
    files[rel] = read(rel)

# 1) O pacote mantido substitui o flutter_markdown original.
files["pubspec.yaml"] = replace_once(
    files["pubspec.yaml"],
    "  flutter_markdown: ^0.7.7+1\n",
    "  flutter_markdown_plus: ^1.0.11\n",
    "dependência flutter_markdown",
)

# 2) Migração do import e contraste para código inline/blocos no tema claro.
mc = files["lib/widgets/message_content.dart"]
mc = replace_once(
    mc,
    "import 'package:flutter_markdown/flutter_markdown.dart';",
    "import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';",
    "import do Markdown",
)
mc = replace_once(
    mc,
    "      code: textStyle.copyWith(fontSize: 13, fontFamily: 'monospace'),",
    """      code: textStyle.copyWith(
        fontSize: 13,
        fontFamily: 'monospace',
        color: isUser ? Colors.white : const Color(0xFFF4F4F5),
        backgroundColor: isUser
            ? Colors.black.withValues(alpha: 0.24)
            : const Color(0xFF28282D),
      ),""",
    "estilo do código inline",
)
mc = replace_once(
    mc,
    "    final foreground = isUser ? Colors.white : GamaColors.textPrimary;\n    final muted = isUser ? Colors.white70 : GamaColors.textMuted;",
    "    // O bloco de código mantém fundo escuro em qualquer tema: usa texto claro.\n    final foreground = isUser ? Colors.white : const Color(0xFFF4F4F5);\n    final muted = isUser ? Colors.white70 : const Color(0xFFA1A1AA);",
    "contraste dos blocos de código",
)
files["lib/widgets/message_content.dart"] = mc

# 3) Modelo Hive: variantes de resposta e metadados compactos de anexos.
files["lib/models/message.dart"] = r'''
import 'package:hive/hive.dart';

part 'message.g.dart';

@HiveType(typeId: 0)
class Message extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String role;

  @HiveField(2)
  String content;

  @HiveField(3)
  final DateTime timestamp;

  @HiveField(4)
  final String conversationId;

  /// JSON pequeno com prompt original + caminho/referência dos anexos.
  /// O conteúdo binário de imagens não é duplicado no histórico.
  @HiveField(5)
  String attachmentMetadataJson;

  /// Todas as versões da mensagem; content é a versão selecionada.
  @HiveField(6)
  List<String> variants;

  @HiveField(7)
  int selectedVariantIndex;

  Message({
    required this.id,
    required this.role,
    required this.content,
    required this.conversationId,
    DateTime? timestamp,
    this.attachmentMetadataJson = '',
    List<String>? variants,
    this.selectedVariantIndex = 0,
  }) : variants = List<String>.from(
         variants ?? (content.isNotEmpty ? <String>[content] : <String>[]),
       ),
       timestamp = timestamp ?? DateTime.now() {
    if (this.variants.isEmpty && content.isNotEmpty) {
      this.variants.add(content);
      selectedVariantIndex = 0;
    } else if (this.variants.isNotEmpty) {
      if (selectedVariantIndex < 0 || selectedVariantIndex >= this.variants.length) {
        selectedVariantIndex = 0;
      }
      if (content.isNotEmpty) this.variants[selectedVariantIndex] = content;
    }
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  int get variantCount => variants.length;

  /// Registra o conteúdo atual e inicia uma nova versão sem apagar a anterior.
  void beginNewVariant({String initialContent = ''}) {
    ensureCurrentVariant();
    variants.add(initialContent);
    selectedVariantIndex = variants.length - 1;
    content = initialContent;
  }

  /// Mantém a variante selecionada consistente antes de persistir no Hive.
  void ensureCurrentVariant() {
    if (variants.isEmpty) {
      if (content.isNotEmpty) {
        variants.add(content);
        selectedVariantIndex = 0;
      }
      return;
    }
    if (selectedVariantIndex < 0 || selectedVariantIndex >= variants.length) {
      selectedVariantIndex = variants.length - 1;
    }
    variants[selectedVariantIndex] = content;
  }

  void selectVariant(int index) {
    if (index < 0 || index >= variants.length) return;
    selectedVariantIndex = index;
    content = variants[index];
  }

  /// Descarta somente a variante que falhou, voltando à última resposta válida.
  void discardCurrentVariant() {
    if (variants.isEmpty) {
      content = '';
      selectedVariantIndex = 0;
      return;
    }
    var index = selectedVariantIndex;
    if (index < 0 || index >= variants.length) index = variants.length - 1;
    variants.removeAt(index);
    if (variants.isEmpty) {
      selectedVariantIndex = 0;
      content = '';
      return;
    }
    selectedVariantIndex = index.clamp(0, variants.length - 1).toInt();
    content = variants[selectedVariantIndex];
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
      };
}
'''
files["lib/models/message.g.dart"] = r'''// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class MessageAdapter extends TypeAdapter<Message> {
  @override
  final int typeId = 0;

  @override
  Message read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Message(
      id: fields[0] as String,
      role: fields[1] as String,
      content: fields[2] as String,
      conversationId: fields[4] as String,
      timestamp: fields[3] as DateTime?,
      attachmentMetadataJson: fields[5] as String? ?? '',
      variants: fields[6] == null ? null : List<String>.from(fields[6] as List),
      selectedVariantIndex: fields[7] as int? ?? 0,
    );
  }

  @override
  void write(BinaryWriter writer, Message obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.role)
      ..writeByte(2)
      ..write(obj.content)
      ..writeByte(3)
      ..write(obj.timestamp)
      ..writeByte(4)
      ..write(obj.conversationId)
      ..writeByte(5)
      ..write(obj.attachmentMetadataJson)
      ..writeByte(6)
      ..write(obj.variants)
      ..writeByte(7)
      ..write(obj.selectedVariantIndex);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
'''

# Sincroniza o conteúdo exibido com a variante selecionada antes de salvar no Hive.
conversation_service = files["lib/services/conversation_service.dart"]
conversation_service = replace_once(
    conversation_service,
    """  Future<void> addMessage(Message message) async {
    await _messagesBox.add(message);
""",
    """  Future<void> addMessage(Message message) async {
    message.ensureCurrentVariant();
    await _messagesBox.add(message);
""",
    "normalizar variante antes de inserir mensagem",
)
conversation_service = replace_once(
    conversation_service,
    """  Future<void> updateMessageContent(Message message, String newContent) async {
    message.content = newContent;
    await message.save();
    notifyListeners();
    // ignore: unawaited_futures
    ConversationSyncService.instance.pushConversation(message.conversationId);
  }
""",
    """  Future<void> updateMessageContent(
    Message message,
    String newContent, {
    bool sync = true,
  }) async {
    message.content = newContent;
    message.ensureCurrentVariant();
    await message.save();
    notifyListeners();
    if (sync) {
      // ignore: unawaited_futures
      ConversationSyncService.instance.pushConversation(message.conversationId);
    }
  }
""",
    "normalizar variante e sincronização condicional ao atualizar mensagem",
)
files["lib/services/conversation_service.dart"] = conversation_service

# 4) O backend aceita e persiste campos opcionais sem invalidar conversas antigas.
backend_route = files["backend/app/routes/conversations.py"]
backend_route = replace_once(
    backend_route,
    """class MessageIn(BaseModel):
    id: str
    role: str
    content: str
    timestamp: Optional[str] = None
    conversationId: Optional[str] = None
""",
    """class MessageIn(BaseModel):
    id: str
    role: str
    content: str
    timestamp: Optional[str] = None
    conversationId: Optional[str] = None
    attachmentMetadataJson: Optional[str] = None
    variants: Optional[List[str]] = None
    selectedVariantIndex: Optional[int] = None
""",
    "campos opcionais no schema de mensagem do backend",
)
files["backend/app/routes/conversations.py"] = backend_route

backend_core = files["backend/app/core/conversations.py"]
backend_core = replace_once(
    backend_core,
    """                messages.append(
                    {
                        "id": mid,
                        "role": role,
                        "content": content,
                        "conversationId": cid,
                        "timestamp": m.get("timestamp")
                        or m.get("createdAt")
                        or _utc_now(),
                    }
                )
""",
    """                normalized_message = {
                    "id": mid,
                    "role": role,
                    "content": content,
                    "conversationId": cid,
                    "timestamp": m.get("timestamp")
                    or m.get("createdAt")
                    or _utc_now(),
                }
                metadata = m.get("attachmentMetadataJson")
                if isinstance(metadata, str) and len(metadata) <= 100_000:
                    normalized_message["attachmentMetadataJson"] = metadata
                raw_variants = m.get("variants")
                if isinstance(raw_variants, list):
                    # Um teto reduz crescimento ilimitado do histórico sincronizado.
                    normalized_variants = [str(v)[:250_000] for v in raw_variants[-12:]]
                    normalized_message["variants"] = normalized_variants
                    try:
                        selected = int(m.get("selectedVariantIndex", 0))
                    except (TypeError, ValueError):
                        selected = 0
                    normalized_message["selectedVariantIndex"] = max(
                        0, min(selected, max(0, len(normalized_variants) - 1))
                    )
                messages.append(normalized_message)
""",
    "persistência de metadados e variantes no backend",
)
files["backend/app/core/conversations.py"] = backend_core

# 5) Atualiza serialização cliente ↔ Railway com campos retrocompatíveis.
sync = files["lib/services/conversation_sync_service.dart"]
sync = replace_once(
    sync,
    """                'content': m.content,
                'conversationId': m.conversationId,
                'timestamp': m.timestamp.toUtc().toIso8601String(),
""",
    """                'content': m.content,
                'conversationId': m.conversationId,
                'timestamp': m.timestamp.toUtc().toIso8601String(),
                'attachmentMetadataJson': m.attachmentMetadataJson,
                'variants': m.variants,
                'selectedVariantIndex': m.selectedVariantIndex,
""",
    "serialização de mensagens para sincronização",
)
sync = replace_once(
    sync,
    """                content: (raw['content'] ?? '').toString(),
                conversationId: id,
                timestamp: _parseDate(raw['timestamp']),
""",
    """                content: (raw['content'] ?? '').toString(),
                conversationId: id,
                timestamp: _parseDate(raw['timestamp']),
                attachmentMetadataJson: (raw['attachmentMetadataJson'] ?? '').toString(),
                variants: raw['variants'] is List
                    ? (raw['variants'] as List).map((v) => v.toString()).toList()
                    : null,
                selectedVariantIndex: int.tryParse(
                  (raw['selectedVariantIndex'] ?? 0).toString(),
                ) ?? 0,
""",
    "leitura das variantes sincronizadas",
)
files["lib/services/conversation_sync_service.dart"] = sync

# 6) ChatScreen: estado separado de erro, anexos reusáveis, variantes e status único.
cs = files["lib/screens/chat_screen.dart"]
cs = replace_once(
    cs,
    "import '../widgets/message_content.dart';\n",
    "import '../widgets/message_content.dart';\nimport '../widgets/chat_status_indicator.dart';\n",
    "import do indicador de status",
)
cs = replace_once(
    cs,
    "  String? _failedAssistantMessageId;\n  String? _retryRawText;\n  List<ProcessedAttachment> _retryAttachments = <ProcessedAttachment>[];",
    "  String? _failedAssistantMessageId;\n  String? _chatErrorMessage;\n  bool _firstTokenReceived = false;\n  Message? _regeneratingAssistantMessage;\n  Message? _regeneratingUserMessage;\n  String? _retryRawText;\n  List<ProcessedAttachment> _retryAttachments = <ProcessedAttachment>[];",
    "estado de erro e regeneração",
)

helpers = r'''  Map<String, dynamic>? _readAttachmentMetadata(Message message) {
    final encoded = message.attachmentMetadataJson.trim();
    if (encoded.isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  String _rawUserPrompt(Message message) {
    final metadata = _readAttachmentMetadata(message);
    final rawText = metadata?['rawText'];
    if (rawText is String) return rawText;
    final marker = message.content.indexOf('Anexos para análise:');
    return marker < 0 ? message.content : message.content.substring(0, marker).trim();
  }

  String _encodeAttachmentMetadata(
    String rawText,
    List<ProcessedAttachment> attachments,
  ) {
    final saved = attachments.map((a) {
      final hasStableReference = RegExp(
        r'\[(?:project_id|video_artifact_id):',
        caseSensitive: false,
      ).hasMatch(a.contentForModel);
      return <String, dynamic>{
        'name': a.name,
        'ext': a.ext,
        'kind': a.kind.name,
        'contentForModel': hasStableReference ? a.contentForModel : '',
        'label': a.label,
        'bytes': a.bytes,
        'sourcePath': a.sourcePath,
        'mimeType': a.mimeType,
      };
    }).toList();
    return jsonEncode({'rawText': rawText, 'attachments': saved});
  }

  Future<List<ProcessedAttachment>> _restoreAttachmentsForMessage(
    Message message,
  ) async {
    final metadata = _readAttachmentMetadata(message);
    final rawAttachments = metadata?['attachments'];
    if (rawAttachments is! List || rawAttachments.isEmpty) return <ProcessedAttachment>[];

    final restored = <ProcessedAttachment>[];
    for (final item in rawAttachments) {
      if (item is! Map) continue;
      final data = Map<String, dynamic>.from(item);
      final name = (data['name'] ?? 'anexo').toString();
      final ext = (data['ext'] ?? '').toString();
      final path = (data['sourcePath'] ?? '').toString();
      final label = (data['label'] ?? name).toString();
      final bytes = int.tryParse((data['bytes'] ?? 0).toString()) ?? 0;
      final mime = data['mimeType']?.toString();
      final savedContent = (data['contentForModel'] ?? '').toString();
      final kindName = (data['kind'] ?? 'other').toString();
      final kind = AttachmentKind.values.firstWhere(
        (value) => value.name == kindName,
        orElse: () => AttachmentKind.other,
      );
      final hasStableReference = RegExp(
        r'\[(?:project_id|video_artifact_id):',
        caseSensitive: false,
      ).hasMatch(savedContent);

      // ZIP/PDF/vídeo já indexado: reutiliza o identificador remoto, sem fazer upload duplicado.
      if (hasStableReference) {
        restored.add(ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: savedContent,
          label: label,
          bytes: bytes,
          sourcePath: path.isEmpty ? null : path,
          mimeType: mime,
        ));
        continue;
      }

      if (path.isNotEmpty && await File(path).exists()) {
        restored.add(await _attachmentService.processFile(path));
        continue;
      }
      throw StateError('O anexo "$name" não está disponível neste dispositivo. Anexe-o novamente para regenerar.');
    }
    return restored;
  }

  String get _chatStatusLabel {
    switch (_streamPhase) {
      case 'searching': return 'Buscando na web…';
      case 'generating_image': return 'Criando imagem…';
      case 'image_analyzing': return 'Analisando imagem…';
      case 'project_analyzing': return 'Analisando projeto…';
      case 'video_queued': return 'Preparando vídeo…';
      case 'video_generating': return 'Gerando vídeo…';
      case 'video_downloading': return 'Salvando vídeo…';
      case 'video_analyzing': return 'Analisando quadros do vídeo…';
      case 'video_editing': return 'Criando versão editada…';
      case 'video_improving': return 'Aprimorando vídeo…';
      case 'thinking': return 'Pensando…';
      default: return 'Gama está respondendo…';
    }
  }

  Future<void> _selectResponseVariant(Message message, int index) async {
    if (_isLoading || index < 0 || index >= message.variants.length) return;
    setState(() => message.selectVariant(index));
    await _service.updateMessageContent(message, message.content);
  }

'''
cs = replace_once(cs, "  bool _canReusePrompt(Message message) {", helpers + "  bool _canReusePrompt(Message message) {", "helpers de anexos e variantes")
cs = replace_between(
    cs,
    "  bool _canReusePrompt(Message message) {",
    "  Future<void> _editAndResend(",
    """  bool _canReusePrompt(Message message) {
    if (!message.isUser) return false;
    if (_readAttachmentMetadata(message) != null) return true;
    final content = message.content;
    // Histórico antigo sem metadados confiáveis não deve ser reenviado incompleto.
    return !content.contains('Anexos para análise:') &&
        !content.contains('[arquivo:') &&
        !content.contains('[project_id:') &&
        !content.contains('[gama_image]') &&
        !content.contains('[gama_image_file]');
  }

""",
    "reuso de prompts com anexos",
)

edit_function = r'''  Future<void> _editAndResend(Message message, int index) async {
    if (_isLoading || !_canReusePrompt(message) || index < 0 || index >= _messages.length) {
      return;
    }
    final editController = TextEditingController(text: _rawUserPrompt(message));
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GamaColors.surfaceElevated,
        title: Text('Editar mensagem', style: TextStyle(color: GamaColors.textPrimary)),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: editController,
            autofocus: true,
            minLines: 3,
            maxLines: 12,
            style: TextStyle(color: GamaColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'Edite o pedido para a Gama',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, editController.text.trim()),
            child: const Text('Reenviar'),
          ),
        ],
      ),
    );
    editController.dispose();
    if (!mounted || edited == null || edited.trim().isEmpty) return;
    if (index >= _messages.length || _messages[index].id != message.id) return;

    List<ProcessedAttachment> restored;
    try {
      restored = await _restoreAttachmentsForMessage(message);
    } catch (e) {
      _snack('Não consegui recuperar os anexos: $e');
      return;
    }
    if (!mounted) return;

    final isLastTurn = index == _messages.length - 2 && _messages.last.isAssistant;
    final displayText = AttachmentService.buildDisplayMessage(edited.trim(), restored);
    if (isLastTurn) {
      final assistant = _messages.last;
      // Persiste as versões atuais antes de abrir a nova variante.
      await _service.updateMessageContent(assistant, assistant.content);
      message.beginNewVariant(initialContent: displayText.isEmpty ? edited.trim() : displayText);
      message.attachmentMetadataJson = restored.isEmpty
          ? ''
          : _encodeAttachmentMetadata(edited.trim(), restored);
      assistant.beginNewVariant();
      setState(() {
        _controller.text = edited.trim();
        _attachments..clear()..addAll(restored);
        _attachmentProcessingFailed = false;
        _chatErrorMessage = null;
        _failedAssistantMessageId = null;
        _regeneratingAssistantMessage = assistant;
        _regeneratingUserMessage = message;
      });
      await _service.updateMessageContent(message, message.content, sync: false);
      await _sendMessage();
      return;
    }

    // Editar um turno antigo ainda cria um novo ramo linear: removem-se os turnos
    // seguintes porque esta conversa ainda não modela ramificações completas.
    final removed = List<Message>.from(_messages.skip(index));
    await _service.deleteMessages(removed, sync: false);
    if (!mounted) return;
    setState(() {
      for (final item in removed) {
        _artifactsByMessageId.remove(item.id);
        _sourcesByMessageId.remove(item.id);
      }
      _messages.removeRange(index, _messages.length);
      _attachments..clear()..addAll(restored);
      _attachmentProcessingFailed = false;
      _chatErrorMessage = null;
      _controller.text = edited.trim();
    });
    await _sendMessage();
  }

'''
cs = replace_between(cs, "  Future<void> _editAndResend(", "  Future<void> _regenerateResponse(", edit_function, "editar mensagem preservando variantes no último turno")

regen_function = r'''  Future<void> _regenerateResponse(int assistantIndex) async {
    if (_isLoading ||
        assistantIndex != _messages.length - 1 ||
        assistantIndex <= 0 ||
        !_messages[assistantIndex].isAssistant) {
      return;
    }
    final prompt = _messages[assistantIndex - 1];
    if (!_canReusePrompt(prompt)) {
      _snack('Esta mensagem antiga não tem referências recuperáveis dos anexos. Anexe os arquivos novamente para regenerar.');
      return;
    }

    List<ProcessedAttachment> restored;
    try {
      restored = await _restoreAttachmentsForMessage(prompt);
    } catch (e) {
      _snack('Não consegui recuperar os anexos: $e');
      return;
    }
    if (!mounted) return;

    final assistant = _messages[assistantIndex];
    // Salva a versão selecionada antes de criar outra variante.
    await _service.updateMessageContent(assistant, assistant.content);
    assistant.beginNewVariant();
    setState(() {
      _controller.text = _rawUserPrompt(prompt);
      _attachments..clear()..addAll(restored);
      _attachmentProcessingFailed = false;
      _failedAssistantMessageId = null;
      _chatErrorMessage = null;
      _regeneratingAssistantMessage = assistant;
      _regeneratingUserMessage = prompt;
    });
    await _sendMessage();
  }

'''
cs = replace_between(cs, "  Future<void> _regenerateResponse(", "  Future<void> _openLink(", regen_function, "regenerar sem apagar resposta anterior")

# Retry de uma variante falhada: mantém versões anteriores no mesmo Message.
retry_function = r'''  Future<void> _retryLastFailedRequest() async {
    if (_isLoading || _failedAssistantMessageId == null) return;
    final failedId = _failedAssistantMessageId!;
    final failedIndex = _messages.indexWhere((m) => m.id == failedId);
    if (failedIndex < 0) return;
    final failedMessage = _messages[failedIndex];

    if (failedMessage.variants.isNotEmpty &&
        failedIndex > 0 &&
        _messages[failedIndex - 1].isUser) {
      final prompt = _messages[failedIndex - 1];
      final rawText = _retryRawText ?? _rawUserPrompt(prompt);
      List<ProcessedAttachment> attachments;
      try {
        attachments = _retryAttachments.isNotEmpty
            ? List<ProcessedAttachment>.from(_retryAttachments)
            : await _restoreAttachmentsForMessage(prompt);
      } catch (e) {
        _snack('Não consegui recuperar os anexos: $e');
        return;
      }
      if (!mounted) return;
      await _service.updateMessageContent(failedMessage, failedMessage.content);
      failedMessage.beginNewVariant();
      setState(() {
        _failedAssistantMessageId = null;
        _chatErrorMessage = null;
        _controller.text = rawText;
        _attachments..clear()..addAll(attachments);
        _regeneratingAssistantMessage = failedMessage;
        _regeneratingUserMessage = prompt;
      });
      await _sendMessage();
      return;
    }

    final rawText = _retryRawText ?? '';
    final attachments = List<ProcessedAttachment>.from(_retryAttachments);
    final start = failedIndex > 0 && _messages[failedIndex - 1].isUser
        ? failedIndex - 1
        : failedIndex;
    final removed = _messages.sublist(start, failedIndex + 1);
    setState(() {
      _messages.removeRange(start, failedIndex + 1);
      _failedAssistantMessageId = null;
      _chatErrorMessage = null;
      _controller.text = rawText;
      _attachments..clear()..addAll(attachments);
    });
    await _service.deleteMessages(removed);
    await _sendMessage();
  }

'''
cs = replace_between(cs, "  Future<void> _retryLastFailedRequest(", "  Future<void> _sendMessage(", retry_function, "tentar novamente sem destruir variantes")

# O _sendMessage distingue turnos novos de regeneração/edição do último turno.
cs = replace_once(
    cs,
    """    final pending = List<ProcessedAttachment>.from(_attachments);
    _retryRawText = rawText;
    _retryAttachments = List<ProcessedAttachment>.from(pending);
    _failedAssistantMessageId = null;
    final apiText = AttachmentService.buildMessageBody(rawText, pending);
""",
    """    final isRegeneration =
        _regeneratingAssistantMessage != null && _regeneratingUserMessage != null;
    final pending = List<ProcessedAttachment>.from(_attachments);
    _retryRawText = rawText;
    _retryAttachments = List<ProcessedAttachment>.from(pending);
    if (_failedAssistantMessageId != null && !isRegeneration) {
      final failedId = _failedAssistantMessageId;
      _messages.removeWhere((m) => m.id == failedId && m.isAssistant);
    }
    _failedAssistantMessageId = null;
    _chatErrorMessage = null;
    _firstTokenReceived = false;
    final apiText = AttachmentService.buildMessageBody(rawText, pending);
""",
    "início do envio e limpeza do erro anterior",
)
cs = replace_once(
    cs,
    """    final userMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: displayText.isEmpty ? apiText : displayText,
      conversationId: widget.conversationId,
    );

    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
      _streamPhase = 'thinking';
    });

    await _service.addMessage(userMessage);
""",
    """    final userMessage = isRegeneration
        ? _regeneratingUserMessage!
        : Message(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            role: 'user',
            content: displayText.isEmpty ? apiText : displayText,
            conversationId: widget.conversationId,
            attachmentMetadataJson: pending.isEmpty
                ? ''
                : _encodeAttachmentMetadata(rawText, pending),
          );

    if (!isRegeneration) {
      setState(() {
        _messages.add(userMessage);
        _isLoading = true;
        _streamPhase = 'thinking';
      });
      await _service.addMessage(userMessage);
    } else {
      setState(() {
        _isLoading = true;
        _streamPhase = 'thinking';
      });
    }
""",
    "construção da mensagem do usuário sem duplicar prompt na regeneração",
)
cs = replace_once(
    cs,
    """    final assistantMessage = Message(
      id: '${DateTime.now().millisecondsSinceEpoch}_ai',
      role: 'assistant',
      content: '',
      conversationId: widget.conversationId,
    );

    setState(() {
      _messages.add(assistantMessage);
      _voiceResponsePending = voiceRequested;
      _voiceResponseBuffer = '';
    });
""",
    """    final assistantMessage = isRegeneration
        ? _regeneratingAssistantMessage!
        : Message(
            id: '${DateTime.now().millisecondsSinceEpoch}_ai',
            role: 'assistant',
            content: '',
            conversationId: widget.conversationId,
          );

    setState(() {
      if (!isRegeneration) _messages.add(assistantMessage);
      _voiceResponsePending = voiceRequested;
      _voiceResponseBuffer = '';
    });
""",
    "reutilização da mesma mensagem de resposta",
)

# O indicador de status não é mostrado depois do primeiro token, inclusive em resposta por voz.
cs = replace_once(
    cs,
    """          final token = event.token;
          if (token == null) return;

          _streamPhase = 'typing';
""",
    """          final token = event.token;
          if (token == null) return;

          _firstTokenReceived = true;
          _streamPhase = 'typing';
""",
    "detectar o primeiro token",
)

# Caso de stream vazio: estado de erro, sem gravar texto de erro como resposta.
cs = replace_once(
    cs,
    """          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            if (isVoiceReply) {
              if (_voiceResponseBuffer.trim().isEmpty) {
                _voiceResponseBuffer =
                    'Não recebi resposta do servidor. Tente novamente.';
              }
            } else if (_messages.last.content.trim().isEmpty) {
              _messages.last.content =
                  'Não recebi resposta do servidor. Tente novamente.';
            }
          }

          if (mounted) {
""",
    """          final latestAssistant = _messages.isNotEmpty && _messages.last.isAssistant
              ? _messages.last
              : null;
          final hasResponse = isVoiceReply
              ? _voiceResponseBuffer.trim().isNotEmpty
              : (latestAssistant?.content.trim().isNotEmpty ?? false);
          if (!hasResponse) {
            latestAssistant?.discardCurrentVariant();
            if (mounted) {
              setState(() {
                _isLoading = false;
                _streamPhase = '';
                _failedAssistantMessageId = latestAssistant?.id;
                _chatErrorMessage = 'Não recebi resposta do servidor. Tente novamente.';
                _voiceResponsePending = false;
                _voiceResponseBuffer = '';
                _speakNextReply = false;
                _isSpeaking = false;
              });
            }
            _regeneratingAssistantMessage = null;
            _regeneratingUserMessage = null;
            return;
          }

          if (mounted) {
""",
    "resposta vazia tratada como erro separado",
)

# Persiste a mensagem final (ou atualiza a mesma mensagem, se foi regenerada).
ondone_start = cs.index("        onDone: () async {")
ondone_end = cs.index("        onError: (e) async {", ondone_start)
ondone = cs[ondone_start:ondone_end]
# A persistência ocorre depois da resposta; se estivermos regenerando, a mesma
# mensagem Hive recebe a nova variante em vez de criar uma duplicata.
ondone = ondone.replace(
    "await _service.addMessage(_messages.last);",
    """if (isRegeneration) {
                await _service.updateMessageContent(_messages.last, _messages.last.content);
              } else {
                await _service.addMessage(_messages.last);
              }""",
)
if ondone.count("if (isRegeneration) {") != 2:
    raise RuntimeError("Não localizei os dois pontos de persistência da resposta. Nenhum arquivo foi alterado.")
ondone = ondone.replace(
    "_retryAttachments = <ProcessedAttachment>[];",
    """_retryAttachments = <ProcessedAttachment>[];
              _chatErrorMessage = null;
              _regeneratingAssistantMessage = null;
              _regeneratingUserMessage = null;""",
)
cs = cs[:ondone_start] + ondone + cs[ondone_end:]

# Falhas de stream são estado visual e não conteúdo de uma mensagem persistente.
onerror_start = cs.index("        onError: (e) async {")
onerror_end = cs.index("        cancelOnError: true,", onerror_start)
old_onerror = cs[onerror_start:onerror_end]
new_onerror = r'''        onError: (e) async {
          _streamUiTimer?.cancel();
          _streamUiTimer = null;
          if (!mounted) return;
          final friendly = e is ChatApiException
              ? e.message
              : 'A resposta foi interrompida. Verifique a conexão e tente novamente.';
          final failed = _messages.isNotEmpty && _messages.last.isAssistant
              ? _messages.last
              : null;
          failed?.discardCurrentVariant();
          setState(() {
            _failedAssistantMessageId = failed?.id;
            _chatErrorMessage = friendly;
            _isLoading = false;
            _streamPhase = '';
            _voiceResponsePending = false;
            _voiceResponseBuffer = '';
            _speakNextReply = false;
            _isSpeaking = false;
          });
          _regeneratingAssistantMessage = null;
          _regeneratingUserMessage = null;
        },
'''
if "await _service.addMessage(failed);" not in old_onerror:
    raise RuntimeError("O tratamento de erro mudou inesperadamente. Nenhum arquivo foi alterado.")
cs = cs[:onerror_start] + new_onerror + cs[onerror_end:]

# Falha ao iniciar a requisição também permanece fora do histórico.
outer_start = cs.index("    } catch (e) {", cs.index("        cancelOnError: true,"))
outer_end = cs.index("\n  Future<void> _stopGeneration()", outer_start)
new_outer = r'''    } catch (e) {
      if (!mounted) return;
      final friendly = e is ChatApiException
          ? e.message
          : 'Não foi possível enviar a mensagem. Verifique a conexão e tente novamente.';
      final failed = _messages.isNotEmpty && _messages.last.isAssistant
          ? _messages.last
          : null;
      failed?.discardCurrentVariant();
      setState(() {
        _failedAssistantMessageId = failed?.id;
        _chatErrorMessage = friendly;
        _isLoading = false;
        _streamPhase = '';
        _voiceResponsePending = false;
        _voiceResponseBuffer = '';
        _speakNextReply = false;
        _isSpeaking = false;
      });
      _regeneratingAssistantMessage = null;
      _regeneratingUserMessage = null;
    }
  }
'''
cs = cs[:outer_start] + new_outer + cs[outer_end:]

# Ao parar manualmente, preserva o trecho produzido e atualiza a variante existente.
cs = replace_once(
    cs,
    """      if (lastMessage.content.isNotEmpty) {
        await _service.addMessage(lastMessage);
      }
""",
    """      if (lastMessage.content.isNotEmpty) {
        if (_regeneratingAssistantMessage != null) {
          await _service.updateMessageContent(lastMessage, lastMessage.content);
        } else {
          await _service.addMessage(lastMessage);
        }
      }
""",
    "salvar resposta interrompida sem duplicar regeneração",
)
cs = replace_once(
    cs,
    """      if (lastMessage != null &&
          lastMessage.isAssistant &&
          lastMessage.content.isEmpty) {
        _messages.remove(lastMessage);
      }
""",
    """      if (lastMessage != null &&
          lastMessage.isAssistant &&
          lastMessage.content.isEmpty) {
        if (lastMessage.variants.isNotEmpty) {
          lastMessage.discardCurrentVariant();
        } else {
          _messages.remove(lastMessage);
        }
      }
""",
    "restaurar variante anterior se parar antes do primeiro token",
)
cs = replace_once(
    cs,
    """    _voiceResponsePending = false;
    _voiceResponseBuffer = '';
    _speakNextReply = false;
    _isSpeaking = false;
    setState(() {
""",
    """    _voiceResponsePending = false;
    _voiceResponseBuffer = '';
    _speakNextReply = false;
    _isSpeaking = false;
    _chatErrorMessage = null;
    _regeneratingAssistantMessage = null;
    _regeneratingUserMessage = null;
    setState(() {
""",
    "limpar estado de regeneração ao parar",
)

# Sugestão de anexos abre o menu nativo, sem submeter a frase como prompt.
cs = replace_once(
    cs,
    """                        onSuggestion: (text) {
                          _controller.text = text;
                          _sendMessage();
                        },
""",
    """                        onSuggestion: (text) {
                          if (text == 'Anexe ZIP/PDF/código e peça uma análise') {
                            _showAttachMenu();
                            return;
                          }
                          _controller.text = text;
                          _sendMessage();
                        },
""",
    "card de anexos na tela vazia",
)

# Status de trabalho/erro fica no balão do assistente. Não exibe status externo.
cs = replace_once(
    cs,
    """                                    if (msg.content.isEmpty && !isUser && _isLoading)
                                      const _TypingDots()
                                    else
                                      MessageContentView(
                                        content: msg.content,
                                        isUser: isUser,
                                        onTapLink: _openLink,
                                      ),
                                    if (!isUser && msg.id == _failedAssistantMessageId) ...[
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: OutlinedButton.icon(
                                          onPressed: _isLoading ? null : _retryLastFailedRequest,
                                          icon: const Icon(Icons.refresh_rounded, size: 18),
                                          label: const Text('Tentar novamente'),
                                        ),
                                      ),
                                    ],
""",
    """                                    if (!isUser &&
                                        msg.id == _failedAssistantMessageId &&
                                        _chatErrorMessage != null) ...[
                                      if (msg.content.trim().isNotEmpty)
                                        MessageContentView(
                                          content: msg.content,
                                          isUser: false,
                                          onTapLink: _openLink,
                                        ),
                                      const SizedBox(height: 8),
                                      ChatStatusIndicator(
                                        label: _chatErrorMessage!,
                                        isError: true,
                                        onRetry: _isLoading ? null : _retryLastFailedRequest,
                                      ),
                                    ] else if (msg.content.isEmpty && !isUser && _isLoading && !_firstTokenReceived)
                                      ChatStatusIndicator(label: _chatStatusLabel)
                                    else if (msg.content.isEmpty && !isUser && _isLoading)
                                      const SizedBox.shrink()
                                    else
                                      MessageContentView(
                                        content: msg.content,
                                        isUser: isUser,
                                        onTapLink: _openLink,
                                      ),
""",
    "status e erros dentro do balão",
)

# Variante selecionável (‹ 2/3 ›) associada à mesma mensagem persistida.
cs = replace_once(
    cs,
    """                                    if (!isUser && (_sourcesByMessageId[msg.id]?.isNotEmpty ?? false))
                                      _sourceChips(msg.id),
""",
    """                                    if (!isUser && (_sourcesByMessageId[msg.id]?.isNotEmpty ?? false))
                                      _sourceChips(msg.id),
                                    if (!isUser && !_isLoading && msg.variants.length > 1)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              tooltip: 'Versão anterior',
                                              visualDensity: VisualDensity.compact,
                                              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                              padding: EdgeInsets.zero,
                                              onPressed: msg.selectedVariantIndex > 0
                                                  ? () => _selectResponseVariant(msg, msg.selectedVariantIndex - 1)
                                                  : null,
                                              icon: const Icon(Icons.chevron_left_rounded, size: 20),
                                            ),
                                            Text(
                                              '${msg.selectedVariantIndex + 1}/${msg.variants.length}',
                                              style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
                                            ),
                                            IconButton(
                                              tooltip: 'Próxima versão',
                                              visualDensity: VisualDensity.compact,
                                              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                              padding: EdgeInsets.zero,
                                              onPressed: msg.selectedVariantIndex < msg.variants.length - 1
                                                  ? () => _selectResponseVariant(msg, msg.selectedVariantIndex + 1)
                                                  : null,
                                              icon: const Icon(Icons.chevron_right_rounded, size: 20),
                                            ),
                                          ],
                                        ),
                                      ),
""",
    "seletor de variantes no balão",
)

# Remove a linha de status duplicada fora da lista de mensagens.
status_start = cs.find("        if (_isLoading || _isSpeaking)\n          Padding(", cs.index("// Messages"))
if status_start < 0:
    raise RuntimeError("Linha externa de status não encontrada; nenhum arquivo foi alterado.")
status_end = cs.find("        // Anexos pendentes", status_start)
if status_end < 0:
    raise RuntimeError("Fim da linha externa de status não encontrado; nenhum arquivo foi alterado.")
cs = cs[:status_start] + cs[status_end:]

# O primeiro token força refresh mesmo no modo de voz (em que texto fica retido).
cs = replace_once(
    cs,
    """          if (_voiceResponsePending) {
            // Mantém a resposta fora da UI enquanto a Gama ainda está
            // gerando. O conteúdo será revelado quando o áudio começar.
            _voiceResponseBuffer += token;
          } else if (_messages.isNotEmpty && _messages.last.isAssistant) {
            _messages.last.content += token;
            // Re-renderiza no máximo a cada ~50 ms, em vez de redesenhar
            // MarkdownBody para cada token do streaming.
            _scheduleStreamUiRefresh();
          }

          if (!_voiceResponsePending) _scrollToBottom();
""",
    """          if (_voiceResponsePending) {
            // Mantém a resposta fora da UI enquanto a Gama ainda está
            // gerando. O conteúdo será revelado quando o áudio começar.
            _voiceResponseBuffer += token;
          } else if (_messages.isNotEmpty && _messages.last.isAssistant) {
            _messages.last.content += token;
          }
          // O status some ao chegar o primeiro token; coalesce o redraw.
          _scheduleStreamUiRefresh();
          if (!_voiceResponsePending) _scrollToBottom();
""",
    "redesenhar na chegada do primeiro token",
)

# Limpa estado transitório quando o usuário troca de conversa.
cs = replace_once(
    cs,
    """      _streamSubscription?.cancel();
      _isLoading = false;
      _attachments.clear();
""",
    """      _streamSubscription?.cancel();
      _isLoading = false;
      _chatErrorMessage = null;
      _failedAssistantMessageId = null;
      _firstTokenReceived = false;
      _regeneratingAssistantMessage = null;
      _regeneratingUserMessage = null;
      _attachments.clear();
""",
    "limpar estado ao trocar de conversa",
)

files["lib/screens/chat_screen.dart"] = cs

# Todas as substituições foram montadas em memória. Só agora gravamos os arquivos,
# e antes guardamos cópias completas, para permitir desfazer sem perder trabalho.
backup_root = ROOT / f"backup_gama_chat_fixes_{_dt.datetime.now().strftime('%Y%m%d_%H%M%S')}"
backup_root.mkdir(parents=True, exist_ok=False)
for rel in files:
    target = ROOT / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = backup_root / rel
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(target, backup)

for rel, content in files.items():
    (ROOT / rel).write_text(content, encoding="utf-8", newline="\n")

print("Correções restantes aplicadas.")
print(f"Backup dos arquivos originais: {backup_root}")
print("Próximos passos:")
print("  1. flutter pub get")
print("  2. flutter analyze")
print("  3. flutter test")
print("  4. Faça deploy/redeploy do backend Railway para persistir variantes e referências entre dispositivos.")
