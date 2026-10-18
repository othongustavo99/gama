#!/usr/bin/env python3
"""Aplica otimizações incrementais do streaming na Gama.

Executar na raiz do projeto Flutter. O script valida os trechos esperados e só
salva arquivos depois que todas as substituições passam. Cria backup automático.
"""
from __future__ import annotations

import datetime as _dt
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()
CHAT = ROOT / "lib" / "screens" / "chat_screen.dart"


def fail(message: str) -> None:
    raise RuntimeError(message)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"Não foi possível aplicar '{label}': esperado 1 trecho, encontrado {count}. Nenhum arquivo foi alterado.\nTrecho: {old[:180]!r}")
    return text.replace(old, new, 1)


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        fail(f"Não foi encontrado o início de '{label}'. Nenhum arquivo foi alterado.")
    b = text.find(end, a + len(start))
    if b < 0:
        fail(f"Não foi encontrado o fim de '{label}'. Nenhum arquivo foi alterado.")
    return text[:a] + replacement + text[b:]


def main() -> int:
    if not CHAT.is_file() or not (ROOT / "pubspec.yaml").is_file():
        print("Execute este script na raiz do projeto Flutter, onde ficam pubspec.yaml e lib/.", file=sys.stderr)
        return 2

    text = CHAT.read_text(encoding="utf-8")
    original = text

    # Se a funcionalidade já estiver aplicada, não tenta aplicar outra vez.
    if "_startStreamRevealTimer()" in text and "_buildMessageContent(msg, isUser)" in text:
        print("As otimizações de streaming parecem já estar aplicadas; nenhum arquivo foi alterado.")
        return 0

    # Imports.
    text = replace_once(
        text,
        "import 'dart:async';\nimport 'dart:convert';\n",
        "import 'dart:async';\nimport 'dart:collection';\nimport 'dart:convert';\n",
        "importar Queue para a fila de caracteres",
    )
    text = replace_once(
        text,
        "import '../widgets/message_content.dart';\n",
        "import '../widgets/message_content.dart';\nimport '../widgets/chat_status_indicator.dart';\n",
        "importar indicador de status",
    )

    # Estado de streaming isolado. O objeto Message mantém o conteúdo completo
    # recebido para persistência/contexto; o ValueNotifier controla apenas a UI.
    text = replace_once(
        text,
        "  StreamSubscription<ChatStreamEvent>? _streamSubscription;\n",
        "  StreamSubscription<ChatStreamEvent>? _streamSubscription;\n\n"
        "  // Isola atualizações do texto em streaming do restante da tela.\n"
        "  final ValueNotifier<String> _streamingTextNotifier = ValueNotifier<String>('');\n"
        "  final Queue<String> _streamRevealQueue = Queue<String>();\n"
        "  Timer? _streamRevealTimer;\n"
        "  Completer<void>? _streamRevealCompleter;\n"
        "  String? _streamingMessageId;\n"
        "  bool _streamReceivedFirstToken = false;\n"
        "  bool _allowStreamAutoScroll = true;\n"
        "  String _webSearchQuery = '';\n"
        "  bool _memorySavedNoticeShown = false;\n"
        "  final Map<String, Widget> _messageContentWidgetCache = {};\n"
        "  final Map<String, String> _messageContentSnapshot = {};\n"
        "  final Map<String, GlobalKey> _messageKeys = {};\n",
        "adicionar estado isolado de streaming",
    )

    helper_methods = r'''  String _streamStatusLabel() {
    switch (_streamPhase) {
      case 'searching':
        final query = _webSearchQuery.trim();
        return query.isEmpty ? 'Buscando na web…' : 'Buscando: $query…';
      case 'project_analyzing':
        return 'Lendo arquivos do projeto…';
      case 'image_analyzing':
        return 'Analisando imagem…';
      case 'generating_image':
        return 'Criando imagem…';
      case 'video_queued':
        return 'Preparando vídeo…';
      case 'video_generating':
        return 'Gerando vídeo…';
      case 'video_downloading':
        return 'Salvando vídeo…';
      case 'video_analyzing':
        return 'Analisando quadros do vídeo…';
      case 'video_editing':
        return 'Criando versão editada…';
      case 'video_improving':
        return 'Aprimorando vídeo…';
      case 'thinking':
        return 'Pensando…';
      default:
        return 'Gama está preparando a resposta…';
    }
  }

  Widget _buildMessageContent(Message message, bool isUser) {
    if (!isUser &&
        message.id == _streamingMessageId &&
        _isLoading &&
        !_voiceResponsePending) {
      return ValueListenableBuilder<String>(
        valueListenable: _streamingTextNotifier,
        builder: (context, visibleText, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: MessageContentView(
                content: visibleText,
                isUser: false,
                onTapLink: _openLink,
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 1, bottom: 2),
              child: _BlinkingStreamCursor(),
            ),
          ],
        ),
      );
    }

    final cached = _messageContentWidgetCache[message.id];
    if (cached != null && _messageContentSnapshot[message.id] == message.content) {
      return cached;
    }
    final widget = MessageContentView(
      content: message.content,
      isUser: isUser,
      onTapLink: _openLink,
    );
    _messageContentWidgetCache[message.id] = widget;
    _messageContentSnapshot[message.id] = message.content;
    return widget;
  }

  void _queueStreamText(String token) {
    _streamRevealQueue.addAll(token.runes.map(String.fromCharCode));
    if (_streamRevealTimer?.isActive ?? false) return;
    _streamRevealCompleter ??= Completer<void>();
    _streamRevealTimer = Timer.periodic(const Duration(milliseconds: 32), (timer) {
      if (!mounted) {
        timer.cancel();
        _streamRevealTimer = null;
        final completer = _streamRevealCompleter;
        _streamRevealCompleter = null;
        if (completer != null && !completer.isCompleted) completer.complete();
        return;
      }
      if (_streamRevealQueue.isEmpty) {
        timer.cancel();
        _streamRevealTimer = null;
        final completer = _streamRevealCompleter;
        _streamRevealCompleter = null;
        if (completer != null && !completer.isCompleted) completer.complete();
        return;
      }
      final backlog = _streamRevealQueue.length;
      final count = backlog >= 900 ? 20 : backlog >= 300 ? 12 : backlog >= 100 ? 7 : 4;
      final chunk = StringBuffer();
      for (var i = 0; i < count && _streamRevealQueue.isNotEmpty; i++) {
        chunk.write(_streamRevealQueue.removeFirst());
      }
      _streamingTextNotifier.value = '${_streamingTextNotifier.value}${chunk.toString()}';
    });
  }

  Future<void> _waitForStreamReveal() async {
    if (_streamRevealQueue.isEmpty && !(_streamRevealTimer?.isActive ?? false)) return;
    final completer = _streamRevealCompleter ??= Completer<void>();
    await completer.future;
  }

  void _finishStreamReveal({bool flush = true}) {
    if (flush && _streamingMessageId != null) {
      for (final message in _messages) {
        if (message.id == _streamingMessageId) {
          _streamingTextNotifier.value = message.content;
          break;
        }
      }
    }
    _streamRevealQueue.clear();
    _streamRevealTimer?.cancel();
    _streamRevealTimer = null;
    final completer = _streamRevealCompleter;
    _streamRevealCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _scrollToMessageTop(String messageId) {
    // Mantém a mensagem enviada ancorada no topo, em vez de perseguir cada token.
    _allowStreamAutoScroll = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _messageKeys[messageId]?.currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.04,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

'''
    text = replace_once(
        text,
        "  String _fallbackConversationTitle(String prompt) {\n",
        helper_methods + "  String _fallbackConversationTitle(String prompt) {\n",
        "adicionar helpers de streaming/status/cache",
    )

    # Scroll automático desliga quando a lista está ancorada na mensagem enviada.
    text = replace_once(
        text,
        "  void _scrollToBottom({bool force = false}) {\n    // O stream pode emitir dezenas de tokens por segundo. Coalescemos os\n",
        "  void _scrollToBottom({bool force = false}) {\n    if (!force && !_allowStreamAutoScroll) return;\n    // O stream pode emitir dezenas de tokens por segundo. Coalescemos os\n",
        "impedir autoscroll após ancorar/arrastar",
    )

    # Limpa o cache ao trocar de conversa.
    text = replace_once(
        text,
        "  void _loadMessages() {\n    setState(() {\n      _messages = _service.getMessages(widget.conversationId);\n      _artifactsByMessageId.clear();\n      _sourcesByMessageId.clear();\n    });\n",
        "  void _loadMessages() {\n    _messageContentWidgetCache.clear();\n    _messageContentSnapshot.clear();\n    _messageKeys.clear();\n    setState(() {\n      _messages = _service.getMessages(widget.conversationId);\n      _artifactsByMessageId.clear();\n      _sourcesByMessageId.clear();\n    });\n",
        "limpar cache ao carregar conversa",
    )

    # Feedback háptico ao copiar.
    text = replace_once(
        text,
        "  Future<void> _copyMessage(Message message) async {\n    await Clipboard.setData(ClipboardData(text: _cleanMessageText(message)));\n    _snack('Mensagem copiada');\n  }\n",
        "  Future<void> _copyMessage(Message message) async {\n    await Clipboard.setData(ClipboardData(text: _cleanMessageText(message)));\n    await HapticFeedback.lightImpact();\n    _snack('Mensagem copiada');\n  }\n",
        "haptic ao copiar",
    )

    # Feedback ao enviar, depois das validações e antes de persistir a mensagem.
    text = replace_once(
        text,
        "    final voiceRequested = _speakNextReply && (pluginFlags['tts'] ?? true);\n\n    final pending = List<ProcessedAttachment>.from(_attachments);\n",
        "    final voiceRequested = _speakNextReply && (pluginFlags['tts'] ?? true);\n"
        "    _memorySavedNoticeShown = false;\n"
        "    await HapticFeedback.lightImpact();\n\n"
        "    final pending = List<ProcessedAttachment>.from(_attachments);\n",
        "haptic e reset do aviso por pedido",
    )

    # Configura o notifier para a nova resposta, sem alterar o fluxo API existente.
    text = replace_once(
        text,
        "    final assistantMessage = Message(\n      id: '${DateTime.now().millisecondsSinceEpoch}_ai',\n      role: 'assistant',\n      content: '',\n      conversationId: widget.conversationId,\n    );\n\n    setState(() {\n",
        "    final assistantMessage = Message(\n      id: '${DateTime.now().millisecondsSinceEpoch}_ai',\n      role: 'assistant',\n      content: '',\n      conversationId: widget.conversationId,\n    );\n\n"
        "    _finishStreamReveal(flush: false);\n"
        "    _streamRevealQueue.clear();\n"
        "    _streamingTextNotifier.value = '';\n"
        "    _streamingMessageId = assistantMessage.id;\n"
        "    _streamReceivedFirstToken = false;\n"
        "    _webSearchQuery = '';\n\n"
        "    setState(() {\n",
        "inicializar notifier da nova resposta",
    )

    # Remove a rolagem antiga para o fim, que competiria com o novo alinhamento.
    text = replace_once(
        text,
        "    _controller.clear();\n    _speechConfirmed = '';\n    _speechPartial = '';\n    _speechLastFinalText = '';\n    _scrollToBottom(force: true);\n\n    final assistantMessage = Message(\n",
        "    _controller.clear();\n    _speechConfirmed = '';\n    _speechPartial = '';\n    _speechLastFinalText = '';\n\n    final assistantMessage = Message(\n",
        "remover scroll para o fim que competiria com a âncora",
    )

    # Captura a posição da mensagem enviada (a chave está no item do ListView).
    text = replace_once(
        text,
        "    setState(() {\n      _messages.add(assistantMessage);\n      _voiceResponsePending = voiceRequested;\n      _voiceResponseBuffer = '';\n    });\n\n    try {\n",
        "    setState(() {\n      _messages.add(assistantMessage);\n      _voiceResponsePending = voiceRequested;\n      _voiceResponseBuffer = '';\n    });\n    _scrollToMessageTop(userMessage.id);\n\n    try {\n",
        "ancorar a mensagem enviada no topo",
    )

    # Eventos de fase, consulta e memória. Não cria setState por token.
    text = replace_once(
        text,
        "          if (event.phase != null) {\n            setState(() => _streamPhase = event.phase!);\n          }\n",
        "          if (event.phase != null || event.webSearchQuery != null) {\n"
        "            final nextPhase = event.phase ?? _streamPhase;\n"
        "            final nextQuery = event.webSearchQuery ?? _webSearchQuery;\n"
        "            if (nextPhase != _streamPhase || nextQuery != _webSearchQuery) {\n"
        "              setState(() {\n"
        "                _streamPhase = nextPhase;\n"
        "                _webSearchQuery = nextQuery;\n"
        "              });\n"
        "            }\n"
        "          }\n"
        "          if (event.memorySaved?.trim().isNotEmpty == true &&\n"
        "              !_memorySavedNoticeShown) {\n"
        "            _memorySavedNoticeShown = true;\n"
        "            ScaffoldMessenger.maybeOf(context)?.showSnackBar(\n"
        "              const SnackBar(\n"
        "                content: Text('Memória atualizada'),\n"
        "                duration: Duration(seconds: 2),\n"
        "                behavior: SnackBarBehavior.floating,\n"
        "              ),\n"
        "            );\n"
        "          }\n",
        "exibir progresso de busca e memória",
    )

    token_old = '''          final token = event.token;
          if (token == null) return;

          _streamPhase = 'typing';
          if (_voiceResponsePending) {
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
'''
    token_new = '''          final token = event.token;
          if (token == null) return;

          _streamPhase = 'typing';
          if (!_streamReceivedFirstToken) {
            _streamReceivedFirstToken = true;
            // Só esta primeira troca redesenha a estrutura da tela para remover
            // o indicador de status; os tokens seguintes atualizam o notifier.
            if (mounted) setState(() {});
          }
          if (_voiceResponsePending) {
            // Mantém a resposta de voz oculta até a reprodução realmente começar.
            _voiceResponseBuffer += token;
          } else if (_messages.isNotEmpty && _messages.last.isAssistant) {
            _messages.last.content += token; // conteúdo completo para contexto/persistência
            if (_messages.last.id == _streamingMessageId) {
              _queueStreamText(token);
            } else {
              _scheduleStreamUiRefresh();
            }
          }

          if (!_voiceResponsePending) _scrollToBottom();
'''
    text = replace_once(text, token_old, token_new, "fila de revelação gradual dos tokens")

    # Ao encerrar normalmente, deixa a fila terminar antes de fixar/cachear Markdown.
    text = replace_once(
        text,
        "          final isVoiceReply = _voiceResponsePending;\n          _voiceResponseBuffer = _voiceResponseBuffer.replaceAll(\n",
        "          final isVoiceReply = _voiceResponsePending;\n"
        "          if (!isVoiceReply) await _waitForStreamReveal();\n"
        "          _voiceResponseBuffer = _voiceResponseBuffer.replaceAll(\n",
        "aguardar revelação antes de finalizar resposta",
    )
    text = replace_once(
        text,
        "          if (mounted) {\n            setState(() {\n              _isLoading = false;\n              _streamPhase = '';\n                    });\n          }\n\n          if (_messages.isNotEmpty && _messages.last.isAssistant) {\n",
        "          if (_messages.isNotEmpty && _messages.last.isAssistant) {\n"
        "            _messageContentWidgetCache.remove(_messages.last.id);\n"
        "            _messageContentSnapshot.remove(_messages.last.id);\n"
        "          }\n"
        "          _streamingMessageId = null;\n"
        "          if (mounted) {\n            setState(() {\n              _isLoading = false;\n              _streamPhase = '';\n                    });\n          }\n\n          if (_messages.isNotEmpty && _messages.last.isAssistant) {\n",
        "encerrar stream e liberar cache do Markdown final",
    )

    # Falhas/parada também encerram o timer, revelam o conteúdo parcial recebido
    # e impedem notifier/cursor órfãos. O tratamento original de erro é preservado.
    text = replace_once(
        text,
        "          final failed = _messages.isNotEmpty && _messages.last.isAssistant\n              ? _messages.last\n              : null;\n          setState(() {\n",
        "          _finishStreamReveal(flush: true);\n"
        "          final failed = _messages.isNotEmpty && _messages.last.isAssistant\n              ? _messages.last\n              : null;\n          setState(() {\n",
        "finalizar timer na falha do stream",
    )
    text = replace_once(
        text,
        "            _isSpeaking = false;\n          });\n          if (failed != null) await _service.addMessage(failed);\n",
        "            _isSpeaking = false;\n"
        "            _streamingMessageId = null;\n"
        "          });\n"
        "          if (failed != null) await _service.addMessage(failed);\n",
        "limpar id do stream após erro",
    )
    text = replace_once(
        text,
        "      setState(() {\n        if (_messages.isNotEmpty && _messages.last.isAssistant) {\n          _messages.last.content = friendly;\n          _failedAssistantMessageId = _messages.last.id;\n        }\n        _isLoading = false;\n        _streamPhase = '';\n      });\n",
        "      _finishStreamReveal(flush: true);\n"
        "      setState(() {\n        if (_messages.isNotEmpty && _messages.last.isAssistant) {\n          _messages.last.content = friendly;\n          _failedAssistantMessageId = _messages.last.id;\n        }\n        _streamingMessageId = null;\n        _isLoading = false;\n        _streamPhase = '';\n      });\n",
        "finalizar timer no erro síncrono",
    )

    # Haptic + completar o texto parcial quando o usuário parar a geração.
    text = replace_once(
        text,
        "  Future<void> _stopGeneration() async {\n    await _streamSubscription?.cancel();\n",
        "  Future<void> _stopGeneration() async {\n    await HapticFeedback.lightImpact();\n    _finishStreamReveal(flush: true);\n    await _streamSubscription?.cancel();\n",
        "haptic e flush ao parar geração",
    )
    text = replace_once(
        text,
        "    _speakNextReply = false;\n    _isSpeaking = false;\n    setState(() {\n      if (lastMessage != null &&\n",
        "    _speakNextReply = false;\n    _isSpeaking = false;\n    _streamingMessageId = null;\n    if (lastMessage != null) {\n      _messageContentWidgetCache.remove(lastMessage.id);\n      _messageContentSnapshot.remove(lastMessage.id);\n    }\n    setState(() {\n      if (lastMessage != null &&\n",
        "limpar cache ao parar geração",
    )

    # Status no balão apenas antes do primeiro token; cacheia o restante das mensagens.
    text = replace_once(
        text,
        "                                    if (msg.content.isEmpty && !isUser && _isLoading)\n                                      const _TypingDots()\n                                    else\n                                      MessageContentView(\n                                        content: msg.content,\n                                        isUser: isUser,\n                                        onTapLink: _openLink,\n                                      ),\n",
        "                                    if (!isUser &&\n"
        "                                        msg.id == _streamingMessageId &&\n"
        "                                        _isLoading &&\n"
        "                                        !_streamReceivedFirstToken)\n"
        "                                      Padding(\n"
        "                                        padding: const EdgeInsets.only(top: 2),\n"
        "                                        child: ChatStatusIndicator(label: _streamStatusLabel()),\n"
        "                                      )\n"
        "                                    else if (msg.content.isEmpty && !isUser && _isLoading)\n"
        "                                      const _TypingDots()\n"
        "                                    else\n"
        "                                      _buildMessageContent(msg, isUser),\n",
        "mover indicador de status para o balão e usar cache",
    )

    # Chave estável por mensagem e isolação de pintura. A transformação é limitada
    # ao itemBuilder para não tocar em outros Aligns do layout.
    item_start = text.find("                        itemBuilder: (context, index) {")
    item_end = text.find("\n              if (_showScrollToBottom)", item_start)
    if item_start < 0 or item_end < 0:
        fail("Não foi possível localizar o bloco da lista de mensagens. Nenhum arquivo foi alterado.")
    item_block = text[item_start:item_end]
    if item_block.count("return Align(\n") != 1:
        fail("O itemBuilder não tem o formato esperado para adicionar RepaintBoundary; nenhum arquivo foi alterado.")
    item_block = item_block.replace(
        "return Align(\n",
        "return RepaintBoundary(\n                            child: Align(\n                              key: _messageKeys.putIfAbsent(msg.id, () => GlobalKey()),\n",
        1,
    )
    tail = "                          );\n                        },\n                      ),"
    if item_block.count(tail) != 1:
        fail("Não foi possível fechar RepaintBoundary com segurança; nenhum arquivo foi alterado.")
    item_block = item_block.replace(
        tail,
        "                            ),\n                          );\n                        },\n                      ),",
        1,
    )
    text = text[:item_start] + item_block + text[item_end:]

    # Notifica quando o usuário inicia uma rolagem manual (wheel/drag) e para o follow.
    text = replace_once(
        text,
        "                    : ListView.builder(\n                        controller: _scrollController,\n",
        "                    : NotificationListener<ScrollNotification>(\n"
        "                        onNotification: (notification) {\n"
        "                          if (notification is UserScrollNotification &&\n"
        "                              notification.direction != ScrollDirection.idle) {\n"
        "                            _allowStreamAutoScroll = false;\n"
        "                          }\n"
        "                          return false;\n"
        "                        },\n"
        "                        child: ListView.builder(\n"
        "                        controller: _scrollController,\n",
        "desligar follow ao rolar manualmente",
    )
    text = replace_once(
        text,
        "                      ),\n              ),\n              if (_showScrollToBottom)\n",
        "                      ),\n                    ),\n              ),\n              if (_showScrollToBottom)\n",
        "fechar NotificationListener da lista",
    )

    # Botão de voltar ao fim explicitamente reativa o follow automático.
    text = replace_once(
        text,
        "                      onPressed: () => _scrollToBottom(force: true),\n",
        "                      onPressed: () {\n"
        "                        _allowStreamAutoScroll = true;\n"
        "                        _scrollToBottom(force: true);\n"
        "                      },\n",
        "reativar follow pelo botão de fim",
    )

    # Remove a linha de status global; agora o status mora dentro da mensagem.
    text = replace_between(
        text,
        "        if (_isLoading || _isSpeaking)\n          Padding(\n",
        "        // Anexos pendentes",
        "",
        "remover status duplicado fora da lista",
    )

    # Ao trocar de conversa, não deixa fila/timer/notifier da conversa anterior ativos.
    text = replace_once(
        text,
        "    if (oldWidget.conversationId != widget.conversationId) {\n      _streamSubscription?.cancel();\n      _isLoading = false;\n",
        "    if (oldWidget.conversationId != widget.conversationId) {\n      _streamSubscription?.cancel();\n      _finishStreamReveal(flush: false);\n      _streamingMessageId = null;\n      _streamReceivedFirstToken = false;\n      _isLoading = false;\n",
        "limpar fila ao trocar conversa",
    )

    # Liberar recursos da animação/notifier.
    text = replace_once(
        text,
        "    _streamSubscription?.cancel();\n    _streamUiTimer?.cancel();\n    _voiceAutoSendTimer?.cancel();\n",
        "    _streamSubscription?.cancel();\n    _streamUiTimer?.cancel();\n    _streamRevealTimer?.cancel();\n"
        "    final revealCompleter = _streamRevealCompleter;\n"
        "    if (revealCompleter != null && !revealCompleter.isCompleted) revealCompleter.complete();\n"
        "    _streamingTextNotifier.dispose();\n"
        "    _voiceAutoSendTimer?.cancel();\n",
        "liberar recursos no dispose",
    )

    # O cursor anima independentemente do widget da mensagem.
    cursor_widget = r'''

class _BlinkingStreamCursor extends StatefulWidget {
  const _BlinkingStreamCursor();

  @override
  State<_BlinkingStreamCursor> createState() => _BlinkingStreamCursorState();
}

class _BlinkingStreamCursorState extends State<_BlinkingStreamCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.15, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _opacity,
        child: Text(
          '▍',
          style: TextStyle(
            color: GamaColors.accentBright,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      );
}
'''
    text = replace_once(
        text,
        "class _ArtifactStatusList extends StatelessWidget {\n",
        cursor_widget + "\nclass _ArtifactStatusList extends StatelessWidget {\n",
        "adicionar cursor piscante",
    )

    # Reduz o custo de composição: deixa de aplicar blur/sombra por mensagem.
    # Limita a substituição ao itemBuilder para não alterar cards de artefatos.
    item_start = text.find("                        itemBuilder: (context, index) {")
    item_end = text.find("\n              if (_showScrollToBottom)", item_start)
    item_block = text[item_start:item_end]
    shadow_old = '''                                  boxShadow: [
                                    BoxShadow(
                                      color: isUser
                                          ? GamaColors.accent.withOpacity(0.10)
                                          : Colors.black.withOpacity(0.16),
                                      blurRadius: isUser ? 18 : 12,
                                      offset: const Offset(0, 5),
                                    ),
                                  ],'''
    item_block = replace_once(item_block, shadow_old, "                                  boxShadow: const [],", "remover sombras com blur das mensagens")
    text = text[:item_start] + item_block + text[item_end:]

    if text == original:
        print("Nenhuma alteração foi necessária.")
        return 0

    # Escreve apenas depois de validar todos os pontos de ancoragem.
    stamp = _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = CHAT.with_name(f"chat_screen.dart.backup_streaming_{stamp}")
    shutil.copy2(CHAT, backup)
    CHAT.write_text(text, encoding="utf-8", newline="")
    print("Otimizações de streaming aplicadas com sucesso.")
    print(f"Backup: {backup}")
    print("Arquivo alterado: lib/screens/chat_screen.dart")
    print("Próximo passo: flutter analyze && flutter test")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        raise SystemExit(1)
