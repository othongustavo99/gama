import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:pasteboard/pasteboard.dart';

import '../core/gama_colors.dart';
import '../core/constants.dart';
import '../models/message.dart';
import '../services/attachment_service.dart';
import '../services/conversation_service.dart';
import '../services/memory_service.dart';
import '../services/ollama_service.dart';
import 'library_screen.dart';
import 'settings_screen.dart';
import '../widgets/message_content.dart';
import '../widgets/chat_status_indicator.dart';
import '../widgets/chat_composer.dart';
import '../services/settings_service.dart';
import '../services/download_service.dart';
import '../utils/message_sanitize.dart';
import '../services/tts_service.dart';
import '../services/plugin_settings_service.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final bool persistentSidebar;

  const ChatScreen({
    super.key,
    required this.conversationId,
    this.persistentSidebar = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _composerFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final OllamaService _ollama = OllamaService();
  final ConversationService _service = ConversationService.instance;
  final MemoryService _memory = MemoryService();

  List<Message> _messages = [];
  bool _isLoading = false;
  String _streamPhase = '';
  final Map<String, List<Map<String, dynamic>>> _artifactsByMessageId = {};
  DateTime? _lastAutoScrollAt;
  bool _scrollCallbackScheduled = false;
  bool _showScrollToBottom = false;
  final ValueNotifier<String> _streamingText = ValueNotifier<String>('');
  final Queue<int> _streamRevealQueue = Queue<int>();
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  Timer? _streamRevealTimer;
  StringBuffer _streamRawText = StringBuffer();
  String _streamSearchQuery = '';
  bool _followStream = true;
  Timer? _voiceAutoSendTimer;
  Timer? _draftSaveTimer;
  bool _restoringDraft = false;
  bool _draggingFiles = false;
  bool _voiceConversationMode = false;
  bool _titleGenerationInProgress = false;
  List<String> _chatModels = List<String>.from(AppConstants.availableModels);
  final Map<String, List<Map<String, dynamic>>> _sourcesByMessageId = {};
  final Map<String, int> _feedbackByMessageId = {};
  StreamSubscription<ChatStreamEvent>? _streamSubscription;

  /// Arquivos anexados (ainda não enviados)
  final List<ProcessedAttachment> _attachments = [];

  /// True enquanto um anexo (esp. ZIP) está sendo processado/indexado.
  bool _processingAttachment = false;
  bool _attachmentProcessingFailed = false;
  int _attachmentsInProgress = 0;
  Completer<void>? _attachmentsReady;
  bool _waitingForAttachment = false;
  String? _processingLabel;
  final _attachmentService = AttachmentService();
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _isListening = false;
  bool _micArmed = false;

  // Buffer permanente do STT. Enquanto o botão estiver ativado, este texto
  // nunca é apagado por silêncio nem pela troca automática de sessão do Android.
  String _speechConfirmed = '';
  String _speechPartial = '';
  String _speechLastFinalText = '';
  int _speechSessionId = 0;
  bool _speechRestartScheduled = false;

  GamaMode _mode = GamaMode.programar;
  bool _speakNextReply = false;
  bool _ttsEarlyStarted = false;
  bool _isSpeaking = false;
  String? _failedAssistantMessageId;
  String? _chatErrorMessage;
  bool _firstTokenReceived = false;
  Message? _regeneratingAssistantMessage;
  Message? _regeneratingUserMessage;
  String? _retryRawText;
  List<ProcessedAttachment> _retryAttachments = <ProcessedAttachment>[];

  // Quando a resposta foi solicitada por voz, o texto recebido fica
  // retido até o áudio realmente começar. Depois, ele é revelado em blocos
  // conforme cada trecho de áudio começa a tocar.
  bool _voiceResponsePending = false;
  String _voiceResponseBuffer = '';
  String? _textBeforeMic;

  @override
  void initState() {
    super.initState();
    _mode = SettingsService.instance.mode;
    _loadMessages();
    _controller.addListener(_queueDraftSave);
    unawaited(_restoreDraft());
    _initSpeech();
    _scrollController.addListener(_handleScrollChange);
    unawaited(_loadChatModels());
    unawaited(_loadFeedback());
  }

  Future<void> _restoreDraft() async {
    final draft = _service.draftFor(widget.conversationId);
    if (!mounted ||
        _controller.text.isNotEmpty ||
        draft == null ||
        draft.isEmpty)
      return;
    _restoringDraft = true;
    _controller.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _restoringDraft = false;
  }

  void _queueDraftSave() {
    if (_restoringDraft) return;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 180), () {
      unawaited(_persistDraft());
    });
  }

  Future<void> _persistDraft([String? draftValue]) async {
    try {
      final text = draftValue ?? _controller.text;
      await _service.saveDraft(widget.conversationId, text);
    } catch (_) {}
  }

  Future<void> _pasteClipboardContent() async {
    if (_isLoading || _waitingForAttachment) return;
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        for (final path in files) {
          await _addPath(path);
        }
        return;
      }
      final image = await Pasteboard.image;
      if (image != null && image.isNotEmpty) {
        final path =
            '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'gama-clipboard-${DateTime.now().microsecondsSinceEpoch}.png';
        await File(path).writeAsBytes(image, flush: true);
        await _addPath(path);
        return;
      }
    } catch (_) {
      // Clipboard text fallback remains available if the image format is absent.
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final nextText = value.text.replaceRange(start, end, text);
    _controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  Future<void> _handleDroppedFiles(DropDoneDetails detail) async {
    if (_isLoading || _waitingForAttachment) return;
    setState(() => _draggingFiles = false);
    for (final file in detail.files) {
      if (file.path.isNotEmpty) await _addPath(file.path);
    }
  }

  Future<void> _loadChatModels() async {
    try {
      final models = await _ollama.listModels();
      if (!mounted || models.isEmpty) return;
      final selected = SettingsService.instance.model;
      setState(() {
        _chatModels = List<String>.unmodifiable({
          ...models,
          if (selected.isNotEmpty) selected,
        });
      });
    } catch (_) {
      // A lista local fica disponível quando o backend está offline.
    }
  }

  Future<void> _loadFeedback() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefix = 'gama_message_feedback_';
      final loaded = <String, int>{};
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(prefix)) continue;
        final value = prefs.getInt(key);
        if (value == 1 || value == -1) {
          loaded[key.substring(prefix.length)] = value!;
        }
      }
      if (mounted) setState(() => _feedbackByMessageId.addAll(loaded));
    } catch (_) {}
  }

  Future<void> _setMessageFeedback(Message message, int value) async {
    final next = _feedbackByMessageId[message.id] == value ? 0 : value;
    setState(() {
      if (next == 0) {
        _feedbackByMessageId.remove(message.id);
      } else {
        _feedbackByMessageId[message.id] = next;
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'gama_message_feedback_${message.id}';
      if (next == 0) {
        await prefs.remove(key);
      } else {
        await prefs.setInt(key, next);
      }
    } catch (_) {}
  }

  void _handleScrollChange() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final nearBottom = position.maxScrollExtent - position.pixels <= 140;
    final show = !nearBottom;
    if (show == _showScrollToBottom) return;
    _showScrollToBottom = show;
    _nearBottomCache = nearBottom;
    if (mounted) setState(() {});
  }

  bool _nearBottomCache = true;

  bool _handleListScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _followStream = false;
    }
    return false;
  }

  void _queueStreamText(String text) {
    _streamRawText.write(text);
    _streamRevealQueue.addAll(text.runes);
    _streamRevealTimer ??= Timer.periodic(const Duration(milliseconds: 30), (
      _,
    ) {
      if (!mounted) return;
      if (_streamRevealQueue.isEmpty) {
        _streamRevealTimer?.cancel();
        _streamRevealTimer = null;
        return;
      }
      final next = StringBuffer();
      for (var i = 0; i < 6 && _streamRevealQueue.isNotEmpty; i++) {
        next.writeCharCode(_streamRevealQueue.removeFirst());
      }
      _streamingText.value = '${_streamingText.value}${next.toString()}';
      if (_followStream) _scrollToBottom(followStream: true);
    });
  }

  void _finishStreamReveal(String finalText) {
    _streamRevealTimer?.cancel();
    _streamRevealTimer = null;
    _streamRevealQueue.clear();
    _streamingText.value = finalText;
  }

  void _scrollToMessageTop(String messageId) {
    final key = _messageKeys.putIfAbsent(messageId, () => GlobalKey());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = key.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.02,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  String _fallbackConversationTitle(String prompt) {
    final cleaned = prompt
        .replaceAll(RegExp(r'https?://\S+'), '')
        .replaceAll(RegExp(r'[`*_#>\[\]()]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final words = cleaned
        .split(' ')
        .where((word) => word.isNotEmpty)
        .take(5)
        .toList();
    if (words.isEmpty) return 'Nova conversa';
    if (words.length < 3) return words.join(' ');
    return words.join(' ');
  }

  Future<void> _ensureConversationTitle({
    required String userMessage,
    required String assistantMessage,
  }) async {
    if (_titleGenerationInProgress) return;
    final conversation = _service.conversationById(widget.conversationId);
    if (conversation == null ||
        (conversation.title.trim().isNotEmpty &&
            conversation.title != 'Nova conversa')) {
      return;
    }
    _titleGenerationInProgress = true;
    try {
      final generated = await _ollama.generateConversationTitle(
        userMessage: userMessage,
        assistantMessage: assistantMessage,
      );
      final title = (generated == null || generated.trim().isEmpty)
          ? _fallbackConversationTitle(userMessage)
          : generated
                .trim()
                .replaceAll(RegExp(r'[\r\n"`]'), '')
                .split(RegExp(r'\s+'))
                .take(7)
                .join(' ');
      if (title.isNotEmpty && mounted) {
        final latest = _service.conversationById(widget.conversationId);
        if (latest != null && latest.title == 'Nova conversa') {
          await _service.renameConversation(widget.conversationId, title);
        }
      }
    } finally {
      _titleGenerationInProgress = false;
    }
  }

  bool _looksTruncated(String content) {
    final text = content.trimRight();
    if (text.length < 180) return false;
    final fenceCount = '```'.allMatches(text).length;
    if (fenceCount.isOdd) return true;
    // Heurística conservadora: finais de frase completos não ganham o botão.
    return RegExp(r'(\.\.\.|…|[:,;—-])$').hasMatch(text) ||
        !RegExp(r'[.!?…)]$').hasMatch(text);
  }

  Future<void> _continueResponse() async {
    if (_isLoading) return;
    _controller.text = 'Continue a resposta anterior de onde parou, sem repetir o que já foi explicado.';
    await _sendMessage();
  }

  Future<void> _submitFollowUp(String prompt) async {
    if (_isLoading) return;
    _controller.text = prompt;
    await _sendMessage();
  }

  Future<void> _toggleVoiceConversation() async {
    if (_voiceConversationMode && (_isSpeaking || TtsService.instance.isBusy)) {
      // Interrupção por toque durante a reprodução: para a fala, mantém o
      // modo de voz ativo e reabre o microfone para a próxima mensagem.
      try {
        await TtsService.instance.stop();
      } catch (_) {}
      if (mounted) setState(() => _isSpeaking = false);
      _micArmed = false;
      _speechSessionId++;
      try {
        await _speech.stop();
      } catch (_) {}
      if (mounted) setState(() => _isListening = false);
      await _toggleListen();
      if (mounted && _micArmed) _snack('Resposta interrompida. Pode falar.');
      return;
    }
    if (_voiceConversationMode) {
      _voiceConversationMode = false;
      _voiceAutoSendTimer?.cancel();
      _voiceAutoSendTimer = null;
      _micArmed = false;
      _speechSessionId++;
      _speechRestartScheduled = false;
      try {
        await _speech.stop();
      } catch (_) {}
      try {
        await TtsService.instance.stop();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isListening = false;
          _isSpeaking = false;
        });
        _snack('Conversa por voz encerrada.');
      }
      return;
    }
    _voiceConversationMode = true;
    if (mounted) setState(() {});
    if (!_micArmed) await _toggleListen();
    if (!mounted) return;
    if (_micArmed) {
      _snack(
        'Conversa por voz ativada. Toque no ícone para interromper a fala ou encerrar.',
      );
    } else {
      _voiceConversationMode = false;
      setState(() {});
      _snack(
        'Não foi possível iniciar a conversa por voz. Verifique a permissão e a disponibilidade do microfone.',
      );
    }
  }

  Future<void> _resumeVoiceConversation() async {
    if (!mounted || !_voiceConversationMode || _isLoading || _micArmed) return;
    try {
      await _toggleListen();
    } catch (_) {}
  }

  Widget _sourceChips(String messageId) {
    final sources =
        _sourcesByMessageId[messageId] ?? const <Map<String, dynamic>>[];
    if (sources.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'FONTES',
            style: TextStyle(
              color: GamaColors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: sources.take(6).map((source) {
              final rawUrl = (source['url'] ?? source['link'] ?? '')
                  .toString()
                  .trim();
              final uri = Uri.tryParse(rawUrl);
              final domain = uri != null && uri.host.isNotEmpty
                  ? uri.host.replaceFirst(RegExp(r'^www\.'), '')
                  : (source['source'] ?? source['title'] ?? 'Fonte').toString();
              final title = (source['title'] ?? domain).toString();
              return ActionChip(
                avatar: const Icon(Icons.link_rounded, size: 14),
                label: Text(
                  domain,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                tooltip: title,
                visualDensity: VisualDensity.compact,
                backgroundColor: GamaColors.surfaceCard,
                side: BorderSide(color: GamaColors.borderSoft),
                onPressed:
                    rawUrl.startsWith('http://') ||
                        rawUrl.startsWith('https://')
                    ? () => _openLink(rawUrl)
                    : null,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  void _showPendingImagePreview(ProcessedAttachment attachment) {
    final path = attachment.sourcePath;
    if (path == null || path.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: GamaColors.surfaceElevated,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 520,
                  maxHeight: 560,
                ),
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                      const Text('Não foi possível abrir esta imagem.'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                attachment.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Fechar'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Junta o trecho confirmado com o parcial da sessão atual.
  /// O parcial nunca substitui o que já foi confirmado.
  void _applySpeechToField() {
    final confirmed = _speechConfirmed.trimRight();
    final partial = _speechPartial.trim();
    final separator = confirmed.isEmpty || partial.isEmpty ? '' : ' ';
    final combined = '$confirmed$separator$partial'.trimLeft();
    if (_controller.text == combined) return;
    _controller.value = _controller.value.copyWith(
      text: combined,
      selection: TextSelection.collapsed(offset: combined.length),
      composing: TextRange.empty,
    );
  }

  String _normalizeSpeechText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Só acrescenta um resultado que ainda não foi confirmado.
  /// Não faz "overlap" de palavras: palavras repetidas pelo usuário são
  /// válidas e não devem ser removidas pelo algoritmo.
  void _appendSpeechConfirmed(String value) {
    final text = _normalizeSpeechText(value);
    if (text.isEmpty) return;

    final confirmed = _normalizeSpeechText(_speechConfirmed);
    if (confirmed.isEmpty) {
      _speechConfirmed = text;
    } else {
      _speechConfirmed = '$confirmed $text';
    }
  }

  void _flushSpeechPartial() {
    final partial = _speechPartial.trim();
    _speechPartial = '';
    if (partial.isEmpty) {
      _applySpeechToField();
      return;
    }
    _appendSpeechConfirmed(partial);
    _applySpeechToField();
  }

  Future<void> _initSpeech() async {
    try {
      _speechReady = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;
          debugPrint('speech status: $status (armed=$_micArmed)');
          if (!_micArmed) return;

          // O Android pode encerrar a sessão interna depois de ~1–3 s sem
          // fala. Isso NÃO significa que o usuário desligou o microfone.
          // O botão continua armado e abrimos outra sessão automaticamente.
          if (status == 'done' || status == 'notListening') {
            _scheduleSpeechRestart();
          }
        },
        onError: (error) {
          debugPrint('speech error: $error');
          if (!_micArmed || !mounted) return;

          // Timeout/erro de silêncio também é tratado como troca de sessão,
          // nunca como desligamento do microfone pelo usuário.
          _scheduleSpeechRestart();
        },
        debugLogging: kDebugMode,
      );
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('speech init: $e');
      _speechReady = false;
    }
  }

  void _scheduleSpeechRestart() {
    if (!_micArmed || !mounted || _speechRestartScheduled) return;
    _speechRestartScheduled = true;

    Future.delayed(const Duration(milliseconds: 850), () async {
      if (!mounted || !_micArmed) {
        _speechRestartScheduled = false;
        return;
      }

      // Damos tempo para o speech_to_text entregar o finalResult depois do
      // evento "done". Só o que realmente ficou sem finalResult é promovido.
      _flushSpeechPartial();

      try {
        await _speech.stop();
      } catch (_) {}

      if (!_micArmed || !mounted) {
        _speechRestartScheduled = false;
        return;
      }

      // Visualmente o microfone continua ativo durante a troca interna.
      if (mounted) setState(() => _isListening = true);

      _speechRestartScheduled = false;
      await _resumeListenIfArmed();
    });
  }

  Future<void> _resumeListenIfArmed() async {
    if (!_micArmed || !mounted || !_speechReady) return;
    try {
      _flushSpeechPartial();
      _speechLastFinalText = '';
      await _startListenSession();
    } catch (e) {
      debugPrint('resume listen: $e');
      if (_micArmed && mounted && !_speechRestartScheduled) {
        Future.delayed(const Duration(milliseconds: 500), () async {
          if (_micArmed && mounted) {
            await _resumeListenIfArmed();
          }
        });
      }
    }
  }

  Future<void> _startListenSession() async {
    if (!_micArmed || !_speechReady) return;

    final sessionId = ++_speechSessionId;
    _flushSpeechPartial();
    _speechLastFinalText = '';

    Future<void> listen() async {
      await _speech.listen(
        localeId: 'pt_BR',
        partialResults: true,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(minutes: 30),
        // O Android pode ignorar valores longos e encerrar por silêncio.
        // onStatus faz a reabertura automática enquanto _micArmed == true.
        pauseFor: const Duration(seconds: 2),
        onResult: (result) => _onSpeechResult(result, sessionId),
      );
    }

    try {
      await listen();
    } catch (_) {
      try {
        await _speech.stop();
      } catch (_) {}
      try {
        await listen();
      } catch (e) {
        debugPrint('start listen failed: $e');
        if (_micArmed && mounted) {
          _scheduleSpeechRestart();
        }
        return;
      }
    }

    if (mounted && _micArmed && sessionId == _speechSessionId) {
      setState(() => _isListening = true);
    }
  }

  void _onSpeechResult(dynamic result, int sessionId) {
    if (!mounted || !_micArmed || sessionId != _speechSessionId) return;

    final words = _normalizeSpeechText(
      (result.recognizedWords as String?) ?? '',
    );
    final isFinal = result.finalResult == true;

    if (words.isEmpty) {
      if (isFinal) {
        // Ao ficar em silêncio o Android costuma entregar um finalResult
        // VAZIO. Antes o parcial era zerado aqui e o texto ainda não
        // confirmado sumia do campo. Agora ele é promovido a confirmado.
        _flushSpeechPartial();
      }
      return;
    }

    if (isFinal) {
      // O final substitui o parcial da mesma sessão. Portanto nunca
      // adicionamos parcial + final, o que era uma das fontes de duplicação.
      if (words.toLowerCase() != _speechLastFinalText.toLowerCase()) {
        _speechLastFinalText = words;
        _appendSpeechConfirmed(words);
      }
      _speechPartial = '';
    } else {
      // partialResults é cumulativo dentro da sessão. Apenas substituímos
      // o parcial visual; o texto confirmado permanece intacto.
      _speechPartial = words;
    }

    _applySpeechToField();

    if (_voiceConversationMode && isFinal && words.isNotEmpty && !_isLoading) {
      _voiceAutoSendTimer?.cancel();
      _voiceAutoSendTimer = Timer(const Duration(milliseconds: 450), () {
        _voiceAutoSendTimer = null;
        if (!mounted ||
            !_voiceConversationMode ||
            _isLoading ||
            _controller.text.trim().isEmpty)
          return;
        _speakNextReply = true;
        unawaited(_sendMessage());
      });
    }

    // Se o Android marcou a sessão como final enquanto o botão ainda está
    // ligado, o próximo status fará a troca automática sem desligar o mic.
  }

  Future<void> _toggleListen() async {
    if (!_speechReady) {
      await _initSpeech();
      if (!_speechReady) {
        _snack(
          'Microfone indisponível.\n'
          'Windows: Configurações → Fala → Português (Brasil)\n'
          'e permita o microfone para o app.',
        );
        return;
      }
    }

    if (_micArmed || _isListening) {
      // Só aqui o usuário desligou o microfone. Silêncio nunca entra neste
      // caminho: enquanto o botão estiver ligado, _micArmed continua true.
      _micArmed = false;
      _speechSessionId++;
      _speechRestartScheduled = false;
      _flushSpeechPartial();
      try {
        await _speech.stop();
      } catch (_) {}
      if (mounted) setState(() => _isListening = false);
      return;
    }

    // Início: o texto que já estava no campo vira a base permanente.
    _speechConfirmed = _controller.text;
    _speechPartial = '';
    _speechLastFinalText = '';
    _speechSessionId++;
    _speechRestartScheduled = false;
    _micArmed = true;
    if (mounted) setState(() => _isListening = true);

    try {
      await _startListenSession();
    } catch (e) {
      _micArmed = false;
      if (mounted) {
        setState(() => _isListening = false);
        _snack('Microfone: $e');
      }
    }
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _streamSubscription?.cancel();
      _streamRevealTimer?.cancel();
      _streamRevealTimer = null;
      _streamRevealQueue.clear();
      _streamRawText = StringBuffer();
      _streamingText.value = '';
      _streamSearchQuery = '';
      _isLoading = false;
      _chatErrorMessage = null;
      _failedAssistantMessageId = null;
      _firstTokenReceived = false;
      _regeneratingAssistantMessage = null;
      _regeneratingUserMessage = null;
      _attachments.clear();
      _micArmed = false;
      _speechConfirmed = '';
      _speechPartial = '';
      _speechLastFinalText = '';
      _speechSessionId++;
      _speechRestartScheduled = false;
      try {
        _speech.stop();
      } catch (_) {}
      _isListening = false;
      _loadMessages();
    }
  }

  void _loadMessages() {
    setState(() {
      _messages = _service.getMessages(widget.conversationId);
      _artifactsByMessageId.clear();
      _sourcesByMessageId.clear();
      _messageKeys.clear();
    });
    _scrollToBottom(force: true);
  }

  void _scrollToBottom({bool force = false, bool followStream = false}) {
    // O stream pode emitir dezenas de tokens por segundo. Coalescemos os
    // callbacks e limitamos animações automáticas para evitar trepidação.
    if (_scrollCallbackScheduled) return;
    if (!force) {
      final now = DateTime.now();
      final last = _lastAutoScrollAt;
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 120)) {
        return;
      }
      _lastAutoScrollAt = now;
    }
    _scrollCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCallbackScheduled = false;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (force ||
          followStream ||
          _nearBottomCache ||
          position.pixels >= position.maxScrollExtent - 120) {
        _scrollController.animateTo(
          position.maxScrollExtent,
          duration: Duration(milliseconds: force ? 180 : 90),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Map<String, dynamic>? _readAttachmentMetadata(Message message) {
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
    return marker < 0
        ? message.content
        : message.content.substring(0, marker).trim();
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
    if (rawAttachments is! List || rawAttachments.isEmpty)
      return <ProcessedAttachment>[];

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
        restored.add(
          ProcessedAttachment(
            name: name,
            ext: ext,
            kind: kind,
            contentForModel: savedContent,
            label: label,
            bytes: bytes,
            sourcePath: path.isEmpty ? null : path,
            mimeType: mime,
          ),
        );
        continue;
      }

      if (path.isNotEmpty && await File(path).exists()) {
        restored.add(await _attachmentService.processFile(path));
        continue;
      }
      throw StateError(
        'O anexo "$name" não está disponível neste dispositivo. Anexe-o novamente para regenerar.',
      );
    }
    return restored;
  }

  String get _chatStatusLabel {
    switch (_streamPhase) {
      case 'searching':
        return _streamSearchQuery.isEmpty
            ? 'Buscando na web…'
            : 'Buscando: $_streamSearchQuery…';
      case 'project_analyzing':
        return 'Lendo arquivos do projeto…';
      case 'generating_image':
        return 'Criando imagem…';
      case 'image_analyzing':
        return 'Analisando imagem…';
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
        return 'Gama está respondendo…';
    }
  }

  Future<void> _selectResponseVariant(Message message, int index) async {
    if (_isLoading || index < 0 || index >= message.variants.length) return;
    setState(() => message.selectVariant(index));
    await _service.updateMessageContent(message, message.content);
  }

  bool _canReusePrompt(Message message) {
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

  Future<void> _editAndResend(Message message, int index) async {
    if (_isLoading ||
        !_canReusePrompt(message) ||
        index < 0 ||
        index >= _messages.length) {
      return;
    }
    final editController = TextEditingController(text: _rawUserPrompt(message));
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GamaColors.surfaceElevated,
        title: Text(
          'Editar mensagem',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
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
            onPressed: () =>
                Navigator.pop(dialogContext, editController.text.trim()),
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

    final isLastTurn =
        index == _messages.length - 2 && _messages.last.isAssistant;
    final displayText = AttachmentService.buildDisplayMessage(
      edited.trim(),
      restored,
    );
    if (isLastTurn) {
      final assistant = _messages.last;
      // Persiste as versões atuais antes de abrir a nova variante.
      await _service.updateMessageContent(assistant, assistant.content);
      message.beginNewVariant(
        initialContent: displayText.isEmpty ? edited.trim() : displayText,
      );
      message.attachmentMetadataJson = restored.isEmpty
          ? ''
          : _encodeAttachmentMetadata(edited.trim(), restored);
      assistant.beginNewVariant();
      setState(() {
        _controller.text = edited.trim();
        _attachments
          ..clear()
          ..addAll(restored);
        _attachmentProcessingFailed = false;
        _chatErrorMessage = null;
        _failedAssistantMessageId = null;
        _regeneratingAssistantMessage = assistant;
        _regeneratingUserMessage = message;
      });
      await _service.updateMessageContent(
        message,
        message.content,
        sync: false,
      );
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
      _attachments
        ..clear()
        ..addAll(restored);
      _attachmentProcessingFailed = false;
      _chatErrorMessage = null;
      _controller.text = edited.trim();
    });
    await _sendMessage();
  }

  Future<void> _regenerateResponse(int assistantIndex) async {
    if (_isLoading ||
        assistantIndex != _messages.length - 1 ||
        assistantIndex <= 0 ||
        !_messages[assistantIndex].isAssistant) {
      return;
    }
    final prompt = _messages[assistantIndex - 1];
    if (!_canReusePrompt(prompt)) {
      _snack(
        'Esta mensagem antiga não tem referências recuperáveis dos anexos. Anexe os arquivos novamente para regenerar.',
      );
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
      _attachments
        ..clear()
        ..addAll(restored);
      _attachmentProcessingFailed = false;
      _failedAssistantMessageId = null;
      _chatErrorMessage = null;
      _regeneratingAssistantMessage = assistant;
      _regeneratingUserMessage = prompt;
    });
    await _sendMessage();
  }

  Future<void> _openLink(String? href) async {
    if (href == null || href.trim().isEmpty) return;
    var raw = href.trim();
    final artifactUri = Uri.tryParse(raw);
    if (artifactUri?.scheme == 'gama-artifact') {
      final segments = artifactUri!.pathSegments;
      final artifactId = segments.isNotEmpty ? segments.first : '';
      final filename =
          artifactUri.queryParameters['filename'] ?? 'gama_arquivo.zip';
      if (artifactUri.host != 'download' ||
          !RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(artifactId)) {
        _snack('Link de download inválido');
        return;
      }
      await _downloadGeneratedArtifact(artifactId, filename);
      return;
    }
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'https://$raw';
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      _snack('Link inválido');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        // fallback Windows / alguns Android
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      _snack('Não abriu o link: $e');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  String _cleanMessageText(Message message) {
    return MessageSanitize.forApi(message.content)
        .replaceAll('[imagem gerada anteriormente nesta conversa]', '')
        .trim();
  }

  Future<void> _copyMessage(Message message) async {
    await Clipboard.setData(ClipboardData(text: _cleanMessageText(message)));
    unawaited(HapticFeedback.lightImpact());
    _snack('Mensagem copiada');
  }

  Widget _messageActions(Message message, int index, bool isLastAssistant) {
    final isUser = message.isUser;
    final canRegenerate =
        isLastAssistant &&
        index > 0 &&
        _messages[index - 1].isUser &&
        _canReusePrompt(_messages[index - 1]);

    Future<void> handleMore(String action) async {
      switch (action) {
        case 'copy':
          await _copyMessage(message);
          break;
        case 'edit':
          await _editAndResend(message, index);
          break;
        case 'download':
          await _downloadMessage(message);
          break;
        case 'share':
          await _shareMessage(message, context);
          break;
      }
    }

    final moreButton = PopupMenuButton<String>(
      tooltip: 'Mais ações',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (action) => unawaited(handleMore(action)),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'copy', child: Text('Copiar')),
        if (isUser && !_isLoading && _canReusePrompt(message))
          const PopupMenuItem(value: 'edit', child: Text('Editar e reenviar')),
        if (!isUser) ...[
          const PopupMenuItem(value: 'download', child: Text('Baixar')),
          const PopupMenuItem(value: 'share', child: Text('Compartilhar')),
        ],
      ],
    );

    if (!isLastAssistant) {
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: SizedBox(height: 36, child: moreButton),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            tooltip: 'Copiar',
            onPressed: () => _copyMessage(message),
            icon: const Icon(Icons.copy_rounded),
            color: GamaColors.textMuted,
            iconSize: 17,
            visualDensity: VisualDensity.compact,
          ),
          if (canRegenerate)
            IconButton(
              tooltip: 'Regenerar resposta',
              onPressed: () => _regenerateResponse(index),
              icon: const Icon(Icons.refresh_rounded),
              color: GamaColors.textMuted,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            tooltip: 'Boa resposta',
            onPressed: () => _setMessageFeedback(message, 1),
            icon: Icon(
              Icons.thumb_up_alt_outlined,
              color: _feedbackByMessageId[message.id] == 1
                  ? GamaColors.accent
                  : GamaColors.textMuted,
            ),
            iconSize: 17,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: 'Resposta ruim',
            onPressed: () => _setMessageFeedback(message, -1),
            icon: Icon(
              Icons.thumb_down_alt_outlined,
              color: _feedbackByMessageId[message.id] == -1
                  ? GamaColors.accent
                  : GamaColors.textMuted,
            ),
            iconSize: 17,
            visualDensity: VisualDensity.compact,
          ),
          moreButton,
        ],
      ),
    );
  }

  Future<void> _downloadMessage(Message message) async {
    try {
      final filePattern = RegExp(
        r'\[gama_image_file\]\s*mime:([^\n]+)\s*path:([^\n]+)\s*\[/gama_image_file\]',
        multiLine: true,
      );
      final legacyPattern = RegExp(
        r'\[gama_image\]\s*mime:([^\n]+)\s*data:([A-Za-z0-9+/=\s]+)\s*\[/gama_image\]',
        multiLine: true,
      );
      var savedImages = 0;
      for (final match in filePattern.allMatches(message.content)) {
        final sourcePath = match.group(2)!.trim();
        if (await File(sourcePath).exists()) {
          await DownloadService.instance.copyFile(sourcePath);
          savedImages++;
        }
      }
      for (final match in legacyPattern.allMatches(message.content)) {
        await DownloadService.instance.saveBase64Image(
          match.group(2)!.replaceAll(RegExp(r'\s'), ''),
          mime: match.group(1)!.trim(),
        );
        savedImages++;
      }

      final text = _cleanMessageText(message);
      String? path;
      if (text.length > 20) {
        path = await DownloadService.instance.saveText(text);
      }
      if (path != null) await DownloadService.instance.openPath(path);
      _snack(
        savedImages > 0
            ? 'Salvo ($savedImages imagem(ns))'
            : 'Arquivo salvo no dispositivo',
      );
    } catch (_) {
      _snack('Não foi possível salvar a mensagem no dispositivo.');
    }
  }

  Future<void> _shareMessage(Message message, BuildContext shareContext) async {
    final text = _cleanMessageText(message);
    if (text.isEmpty) {
      _snack('Não há texto para compartilhar');
      return;
    }

    try {
      final renderObject = shareContext.findRenderObject();
      final box = renderObject is RenderBox ? renderObject : null;
      final origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await SharePlus.instance.share(
        ShareParams(
          title: 'Mensagem da Gama',
          text: text,
          sharePositionOrigin: origin,
        ),
      );
    } catch (error) {
      _snack('Não consegui compartilhar a mensagem: $error');
    }
  }

  Future<void> _downloadGeneratedArtifact(
    String artifactId,
    String filename,
  ) async {
    late final String savedPath;
    try {
      savedPath = await DownloadService.instance.downloadArtifact(
        '/artifacts/$artifactId/download',
        filename: filename,
      );
      final file = File(savedPath);
      final lowerName = filename.toLowerCase();
      final kind = lowerName.endsWith('.pdf')
          ? 'pdf'
          : (lowerName.endsWith('.mp4') ||
                lowerName.endsWith('.webm') ||
                lowerName.endsWith('.mov') ||
                lowerName.endsWith('.m4v') ||
                lowerName.endsWith('.mkv'))
          ? 'video'
          : 'zip';
      await LibraryScreen.addEntry(
        name: filename,
        kind: kind,
        bytes: await file.length(),
        sourcePath: savedPath,
      );
    } catch (e) {
      _snack('Não consegui baixar o arquivo: $e');
      return;
    }

    try {
      await DownloadService.instance.openGeneratedFile(savedPath);
    } catch (e) {
      _snack('Arquivo salvo na Biblioteca, mas não consegui abrir: $e');
    }
  }

  Future<void> _showAttachMenu() async {
    if (_isLoading || _waitingForAttachment) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: GamaColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: GamaColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(
                  'Anexar',
                  style: TextStyle(
                    color: GamaColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: Icon(
                    Icons.photo_camera_outlined,
                    color: GamaColors.accent,
                  ),
                  title: Text(
                    'Câmera',
                    style: TextStyle(color: GamaColors.textPrimary),
                  ),
                  subtitle: Text(
                    'Tirar foto',
                    style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFromCamera();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.photo_library_outlined,
                    color: GamaColors.accent,
                  ),
                  title: Text(
                    'Galeria',
                    style: TextStyle(color: GamaColors.textPrimary),
                  ),
                  subtitle: Text(
                    'Escolher imagem',
                    style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFromGallery();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.folder_open_rounded,
                    color: GamaColors.accent,
                  ),
                  title: Text(
                    'Arquivos',
                    style: TextStyle(color: GamaColors.textPrimary),
                  ),
                  subtitle: Text(
                    'PDF, ZIP, código, documentos…',
                    style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFiles();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<bool> _ensurePermission(Permission permission, String label) async {
    var status = await permission.status;
    if (status.isGranted || status.isLimited) return true;
    status = await permission.request();
    if (status.isGranted || status.isLimited) return true;
    if (status.isPermanentlyDenied) {
      _snack('Permissão de $label negada. Ative nas configurações do app.');
      await openAppSettings();
      return false;
    }
    _snack('Permissão de $label necessária');
    return false;
  }

  Future<void> _pickFromCamera() async {
    final ok = await _ensurePermission(Permission.camera, 'câmera');
    if (!ok) return;
    try {
      final picker = ImagePicker();
      final shot = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1920,
      );
      if (shot == null) return;
      await _addPath(shot.path);
    } catch (e) {
      _snack('Câmera: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    // image_picker usa o seletor de fotos do sistema: não exige permissão.
    try {
      final picker = ImagePicker();
      final img = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1920,
      );
      if (img == null) return;
      await _addPath(img.path);
    } catch (e) {
      _snack('Galeria: $e');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (result == null || result.isEmpty) return;
      // Processa sequencialmente para não iniciar vários uploads grandes em
      // paralelo (Android tem memória limitada e o backend também é protegido).
      for (final f in result) {
        final path = f.path;
        if (path == null || path.isEmpty) {
          _snack('${f.name}: caminho indisponível');
          continue;
        }
        await _addPath(path);
      }
    } catch (e) {
      _snack('Arquivos: $e');
    }
  }

  Future<void> _addPath(String path) async {
    final name = path.split(RegExp(r'[/\\]')).last;
    final isZip = name.toLowerCase().endsWith('.zip');
    if (_attachmentsInProgress == 0) {
      _attachmentsReady = Completer<void>();
      _attachmentProcessingFailed = false;
    }
    _attachmentsInProgress++;
    setState(() {
      _processingAttachment = true;
      _processingLabel = isZip ? 'Indexando $name…' : 'Anexando $name…';
    });
    try {
      final processed = await _attachmentService.processFile(path);
      if (!mounted) return;
      setState(() {
        _attachments.add(processed);
      });
      await LibraryScreen.addEntry(
        name: processed.name,
        kind: processed.kind.name,
        bytes: processed.bytes,
        sourcePath: path,
      );
    } catch (e) {
      _attachmentProcessingFailed = true;
      if (!mounted) return;
      _snack('$e');
    } finally {
      _attachmentsInProgress--;
      if (_attachmentsInProgress == 0) {
        final ready = _attachmentsReady;
        _attachmentsReady = null;
        if (mounted) {
          setState(() {
            _processingAttachment = false;
            _processingLabel = null;
          });
        }
        if (ready != null && !ready.isCompleted) ready.complete();
      }
    }
  }

  String _buildMessageWithAttachments(String userText) {
    return AttachmentService.buildMessageBody(userText, _attachments);
  }

  // imagens nativas → POST /chat images[]; docs → texto no content

  /// Comandos locais /memoria — não vão para o modelo.
  Future<bool> _handleSlashCommand(String text) async {
    final t = text.trim();
    final lower = t.toLowerCase();

    if (lower == '/memoria' ||
        lower == '/memoria listar' ||
        lower == '/memory') {
      try {
        final facts = await _memory.listFacts();
        if (facts.isEmpty) {
          _snack('Memória vazia');
        } else {
          final body = facts.map((f) => '• ${f.text}').join('\n');
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: GamaColors.surfaceCard,
              title: Text(
                'Memória',
                style: TextStyle(color: GamaColors.textPrimary),
              ),
              content: SingleChildScrollView(
                child: Text(
                  body,
                  style: TextStyle(color: GamaColors.textSecondary),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'Fechar',
                    style: TextStyle(color: GamaColors.accent),
                  ),
                ),
              ],
            ),
          );
        }
      } catch (e) {
        _snack('Erro ao listar memória: $e');
      }
      return true;
    }

    if (lower == '/memoria limpar' || lower == '/memory clear') {
      try {
        await _memory.clear();
        _snack('Memória limpa');
      } catch (e) {
        _snack('Erro ao limpar: $e');
      }
      return true;
    }

    if (lower.startsWith('/memoria ') || lower.startsWith('/memory ')) {
      final fact = t
          .replaceFirst(
            RegExp(r'^/(memoria|memory)\s+', caseSensitive: false),
            '',
          )
          .trim();
      if (fact.length >= 3) {
        try {
          await _memory.addFact(fact);
          _snack('Salvei na memória: $fact');
        } catch (e) {
          _snack('Erro ao salvar: $e');
        }
        return true;
      }
    }

    return false;
  }

  Future<void> _maybeSpeak(
    String text, {
    bool revealWhileSpeaking = false,
  }) async {
    final ttsEnabled = await PluginSettingsService.instance.isEnabled('tts');
    final want =
        ttsEnabled && (_speakNextReply || SettingsService.instance.ttsAuto);
    _speakNextReply = false;
    if (!want) return;

    final t = text.trim();
    if (t.isEmpty || !mounted) return;

    // Garante que qualquer fala anterior seja interrompida antes de iniciar
    // a nova (ex.: usuário enviou outra mensagem enquanto a Gama falava).
    if (TtsService.instance.isBusy) {
      await TtsService.instance.stop();
    }

    // A geração do texto terminou, mas a Gama ainda está entregando
    // a resposta em áudio. O indicador permanece no mesmo lugar do
    // "Pensando..." até a reprodução terminar de verdade.
    setState(() => _isSpeaking = true);

    try {
      if (!revealWhileSpeaking) {
        // Comportamento original: fala o texto inteiro, frase a frase.
        await TtsService.instance.speakFull(t);
        return;
      }

      // Somente para o botão "Enviar e ouvir": o texto já foi recebido,
      // mas permanece oculto até o primeiro áudio começar a tocar.
      await TtsService.instance.speakFull(
        t,
        onChunkPlaybackStart: (chunk) async {
          if (!mounted) return;
          setState(() {
            if (_messages.isNotEmpty && _messages.last.isAssistant) {
              _messages.last.content +=
                  (_messages.last.content.isEmpty ? '' : ' ') + chunk;
            }
          });
          _scrollToBottom();
        },
      );
    } finally {
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
    }
  }

  Future<void> _storeGeneratedImage({
    required String data,
    required String mime,
    required String messageId,
  }) async {
    String block;
    try {
      final bytes = base64Decode(data);
      final normalizedMime = mime.toLowerCase().split(';').first.trim();
      final ext = switch (normalizedMime) {
        'image/jpeg' || 'image/jpg' => 'jpg',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        'image/bmp' => 'bmp',
        _ => 'png',
      };
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = await LibraryScreen.addEntry(
        name: 'gama_gerada_${timestamp}_$messageId.$ext',
        kind: 'image',
        bytes: bytes.length,
        sourceBytes: bytes,
      );
      if (path == null || path.isEmpty) {
        // Último recurso de compatibilidade: mantém a imagem visível caso o
        // armazenamento local falhe, embora esse caso excepcional ocupe mais
        // espaço no Hive do que o caminho de arquivo.
        block =
            '\n[gama_image]\nmime:$normalizedMime\ndata:${base64Encode(bytes)}\n[/gama_image]\n';
      } else {
        block =
            '\n[gama_image_file]\nmime:$normalizedMime\npath:$path\n[/gama_image_file]\n';
      }
    } catch (_) {
      block = '\n[gama_image]\nmime:$mime\ndata:$data\n[/gama_image]\n';
    }

    if (!mounted) return;
    Message? target;
    for (final message in _messages) {
      if (message.id == messageId) {
        target = message;
        break;
      }
    }
    final messageToUpdate = target;
    if (messageToUpdate == null) return;
    setState(
      () => messageToUpdate.content = '${messageToUpdate.content}$block',
    );
    if (messageToUpdate.isInBox) {
      try {
        await _service.updateMessageContent(
          messageToUpdate,
          messageToUpdate.content,
        );
      } catch (_) {}
    }
    _scrollToBottom();
  }

  Future<void> _retryLastFailedRequest() async {
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
        _attachments
          ..clear()
          ..addAll(attachments);
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
      _attachments
        ..clear()
        ..addAll(attachments);
    });
    await _service.deleteMessages(removed);
    await _sendMessage();
  }

  Future<void> _sendMessage() async {
    if (_isLoading || _waitingForAttachment) return;

    // A seleção do arquivo pode terminar antes da indexação no servidor.
    // Só envie depois que o project_id estiver pronto e incluído no anexo.
    if (_processingAttachment) {
      final ready = _attachmentsReady;
      if (ready != null) {
        setState(() => _waitingForAttachment = true);
        _snack('Aguarde a indexação do anexo para enviar a mensagem.');
        try {
          await ready.future;
        } finally {
          if (mounted) setState(() => _waitingForAttachment = false);
        }
      }
      if (!mounted) return;
    }
    if (_attachmentProcessingFailed) {
      _snack(
        'O anexo não foi processado. Tente anexá-lo novamente antes de enviar.',
      );
      return;
    }

    if (_voiceConversationMode) _speakNextReply = true;
    final rawText = _controller.text.trim();
    if ((rawText.isEmpty && _attachments.isEmpty) || _isLoading) return;

    final pluginFlags = await PluginSettingsService.instance.load();
    if (_attachments.isNotEmpty && pluginFlags['attachments'] == false) {
      _snack(
        'Anexos está desativado em Plugins. Ative o recurso para enviar arquivos.',
      );
      return;
    }
    if (_attachments.any((a) => a.isNativeImage) &&
        pluginFlags['vision'] == false) {
      _snack(
        'Visão está desativada em Plugins. Ative o recurso para analisar imagens.',
      );
      return;
    }
    if (pluginFlags['tts'] == false &&
        (_speakNextReply || SettingsService.instance.ttsAuto)) {
      _speakNextReply = false;
      _snack(
        'Voz (TTS) está desativada em Plugins; a resposta será exibida em texto.',
      );
    }

    // Se a Gama ainda estiver falando a resposta anterior, interrompe
    // imediatamente e começa a tratar a mensagem atual.
    if (_isSpeaking || TtsService.instance.isBusy) {
      await TtsService.instance.stop();
      if (mounted) setState(() => _isSpeaking = false);
    }

    if (_micArmed || _isListening) {
      _micArmed = false;
      _speechSessionId++;
      _speechRestartScheduled = false;
      _flushSpeechPartial();
      try {
        await _speech.stop();
      } catch (_) {}
      if (mounted) setState(() => _isListening = false);
    }

    // Comandos de memória
    if (rawText.startsWith('/') && _attachments.isEmpty) {
      final handled = await _handleSlashCommand(rawText);
      if (handled) {
        _controller.clear();
        return;
      }
    }

    final voiceRequested = _speakNextReply && (pluginFlags['tts'] ?? true);

    unawaited(HapticFeedback.lightImpact());
    _followStream = true;
    _streamSearchQuery = '';
    _streamRawText = StringBuffer();
    _streamRevealQueue.clear();
    _streamingText.value = '';

    final isRegeneration =
        _regeneratingAssistantMessage != null &&
        _regeneratingUserMessage != null;
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
    final displayText = AttachmentService.buildDisplayMessage(rawText, pending);
    final imagePayload = AttachmentService.buildImagesPayload(pending);
    _attachments.clear();

    final userMessage = isRegeneration
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
    if (!mounted) return;
    _controller.clear();
    _speechConfirmed = '';
    _speechPartial = '';
    _speechLastFinalText = '';
    if (!isRegeneration) _scrollToMessageTop(userMessage.id);

    final assistantMessage = isRegeneration
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

    try {
      final apiMessages = <Message>[
        for (final m in _messages)
          if (m.content.isNotEmpty)
            m.id == userMessage.id
                ? Message(
                    id: m.id,
                    role: m.role,
                    content: apiText,
                    conversationId: m.conversationId,
                    timestamp: m.timestamp,
                  )
                : m,
      ];

      // Fala (botão de ouvir / TTS automático) ou modo Conversar →
      // pede resposta só em frases naturais, sem listas/código/símbolos.
      final willSpeak =
          (pluginFlags['tts'] ?? true) &&
          (voiceRequested || SettingsService.instance.ttsAuto);
      final stream = _ollama.chatStream(
        messages: apiMessages,
        images: imagePayload.isEmpty ? null : imagePayload,
        voiceMode: willSpeak,
        chatMode: _mode == GamaMode.conversar ? 'conversar' : 'programar',
        conversationId: widget.conversationId,
      );

      _streamSubscription = stream.listen(
        (event) {
          if (!mounted) return;

          if (event.phase != null) {
            setState(() => _streamPhase = event.phase!);
          }
          if (event.webSearchQuery != null &&
              event.webSearchQuery!.trim().isNotEmpty) {
            _streamSearchQuery = event.webSearchQuery!.trim();
            _streamPhase = 'searching';
            if (mounted) setState(() {});
          }
          if (event.memorySaved != null &&
              event.memorySaved!.trim().isNotEmpty) {
            _snack('Memória atualizada');
          }
          if (event.sources != null &&
              _messages.isNotEmpty &&
              _messages.last.isAssistant) {
            _sourcesByMessageId[_messages.last.id] =
                List<Map<String, dynamic>>.from(event.sources!);
            setState(() {});
          }

          // Metadados confiáveis de entrega: separam integridade do ZIP da
          // validação sintática real dos arquivos que ele contém.
          if (event.artifact != null &&
              _messages.isNotEmpty &&
              _messages.last.isAssistant) {
            final artifacts = _artifactsByMessageId.putIfAbsent(
              _messages.last.id,
              () => <Map<String, dynamic>>[],
            );
            artifacts.add(Map<String, dynamic>.from(event.artifact!));
            setState(() {});
          }

          // Imagem gerada pelo backend (GPT Image 2.5 Sunburst)
          if (event.imageBase64 != null && event.imageBase64!.isNotEmpty) {
            final assistant = _messages.where((m) => m.isAssistant).toList();
            if (assistant.isNotEmpty) {
              unawaited(
                _storeGeneratedImage(
                  data: event.imageBase64!,
                  mime: event.imageMime ?? 'image/png',
                  messageId: assistant.last.id,
                ),
              );
            }
          }

          final token = event.token;
          if (token == null) return;

          final isFirstToken = !_firstTokenReceived;
          _firstTokenReceived = true;
          _streamPhase = 'typing';
          if (_voiceResponsePending) {
            // Mantém a resposta fora da UI enquanto a Gama ainda está
            // gerando. O conteúdo será revelado quando o áudio começar.
            _voiceResponseBuffer += token;
          } else if (_messages.isNotEmpty && _messages.last.isAssistant) {
            _queueStreamText(token);
          }
          if (isFirstToken && mounted) setState(() {});
        },
        onDone: () async {
          _streamRevealTimer?.cancel();
          _streamRevealTimer = null;
          final isVoiceReply = _voiceResponsePending;
          _voiceResponseBuffer = _voiceResponseBuffer
              .replaceAll(
                RegExp(
                  r'\[\[GAMA_FILES\]\][\s\S]*?\[\[/GAMA_FILES\]\]',
                  caseSensitive: false,
                ),
                '',
              )
              .trim();
          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            final completedText = _streamRawText
                .toString()
                .replaceAll(
                  RegExp(
                    r'\[\[GAMA_FILES\]\][\s\S]*?\[\[/GAMA_FILES\]\]',
                    caseSensitive: false,
                  ),
                  '',
                )
                .trim();
            _messages.last.content = isVoiceReply ? '' : completedText;
            _finishStreamReveal(isVoiceReply ? '' : completedText);
          }
          final latestAssistant =
              _messages.isNotEmpty && _messages.last.isAssistant
              ? _messages.last
              : null;
          final hasResponse = isVoiceReply
              ? _voiceResponseBuffer.trim().isNotEmpty
              : (_streamingText.value.trim().isNotEmpty ||
                    (latestAssistant?.content.trim().isNotEmpty ?? false));
          if (!hasResponse) {
            latestAssistant?.discardCurrentVariant();
            if (mounted) {
              setState(() {
                _isLoading = false;
                _streamPhase = '';
                _failedAssistantMessageId = latestAssistant?.id;
                _chatErrorMessage =
                    'Não recebi resposta do servidor. Tente novamente.';
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
            setState(() {
              _isLoading = false;
              _streamPhase = '';
            });
          }

          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            _ttsEarlyStarted = false;
            final responseText = isVoiceReply
                ? _voiceResponseBuffer
                : _messages.last.content;
            try {
              if (isVoiceReply) {
                await _maybeSpeak(responseText, revealWhileSpeaking: true);
              } else {
                await _maybeSpeak(responseText);
              }

              // Persiste a resposta completa depois da reprodução. Para o
              // fluxo normal, isso continua ocorrendo sem alteração visual.
              if (isVoiceReply && mounted) {
                setState(() {
                  if (_messages.isNotEmpty &&
                      _messages.last.isAssistant &&
                      _messages.last.content.trim() != responseText.trim()) {
                    _messages.last.content = responseText;
                  }
                });
              }
              if (isRegeneration) {
                await _service.updateMessageContent(
                  _messages.last,
                  _messages.last.content,
                );
              } else {
                await _service.addMessage(_messages.last);
              }
              unawaited(
                _ensureConversationTitle(
                  userMessage: rawText.isEmpty ? 'Arquivo anexado' : rawText,
                  assistantMessage: responseText,
                ),
              );
              _failedAssistantMessageId = null;
              _retryRawText = null;
              _retryAttachments = <ProcessedAttachment>[];
              _chatErrorMessage = null;
              _regeneratingAssistantMessage = null;
              _regeneratingUserMessage = null;
            } catch (e) {
              // Se o áudio falhar, ainda mostramos a resposta completa para
              // não perder a mensagem que o servidor já gerou.
              if (isVoiceReply && mounted) {
                setState(() {
                  if (_messages.isNotEmpty && _messages.last.isAssistant) {
                    _messages.last.content = responseText;
                  }
                });
              }
              if (isRegeneration) {
                await _service.updateMessageContent(
                  _messages.last,
                  _messages.last.content,
                );
              } else {
                await _service.addMessage(_messages.last);
              }
              unawaited(
                _ensureConversationTitle(
                  userMessage: rawText.isEmpty ? 'Arquivo anexado' : rawText,
                  assistantMessage: responseText,
                ),
              );
              _failedAssistantMessageId = null;
              _retryRawText = null;
              _retryAttachments = <ProcessedAttachment>[];
              _chatErrorMessage = null;
              _regeneratingAssistantMessage = null;
              _regeneratingUserMessage = null;
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Voz: $e'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } finally {
              _voiceResponsePending = false;
              _voiceResponseBuffer = '';
              if (_voiceConversationMode) unawaited(_resumeVoiceConversation());
            }
          }
        },
        onError: (e) async {
          _streamRevealTimer?.cancel();
          _streamRevealTimer = null;
          _streamRevealQueue.clear();
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
        cancelOnError: true,
      );
    } catch (e) {
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

  Future<void> _stopGeneration() async {
    unawaited(HapticFeedback.lightImpact());
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    _finishStreamReveal(_streamRawText.toString());
    await TtsService.instance.stop();
    _isSpeaking = false;
    if (!mounted) return;
    final lastMessage = _messages.isNotEmpty ? _messages.last : null;
    if (lastMessage != null && lastMessage.isAssistant) {
      if (_voiceResponsePending && _voiceResponseBuffer.isNotEmpty) {
        lastMessage.content = _voiceResponseBuffer;
      } else if (_streamRawText.length > 0) {
        lastMessage.content = _streamRawText.toString();
      }
      if (lastMessage.content.isNotEmpty) {
        if (_regeneratingAssistantMessage != null) {
          await _service.updateMessageContent(lastMessage, lastMessage.content);
        } else {
          await _service.addMessage(lastMessage);
        }
      }
    }
    _voiceResponsePending = false;
    _voiceResponseBuffer = '';
    _speakNextReply = false;
    _isSpeaking = false;
    _chatErrorMessage = null;
    _regeneratingAssistantMessage = null;
    _regeneratingUserMessage = null;
    setState(() {
      if (lastMessage != null &&
          lastMessage.isAssistant &&
          lastMessage.content.isEmpty) {
        if (lastMessage.variants.isNotEmpty) {
          lastMessage.discardCurrentVariant();
        } else {
          _messages.remove(lastMessage);
        }
      }
      _isLoading = false;
      _streamPhase = '';
    });
  }

  Future<void> _clearCurrentConversation() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GamaColors.surfaceCard,
        title: Text(
          'Limpar esta conversa?',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: Text(
          'Isso apaga todas as mensagens desta conversa.',
          style: TextStyle(color: GamaColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancelar',
              style: TextStyle(color: GamaColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Apagar', style: TextStyle(color: GamaColors.error)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final messages = _service.getMessages(widget.conversationId);
      for (final msg in messages) {
        await msg.delete();
      }
      setState(() => _messages.clear());
    }
  }

  @override
  void dispose() {
    _micArmed = false;
    try {
      _speech.stop();
    } catch (_) {}
    _streamSubscription?.cancel();
    _streamRevealTimer?.cancel();
    _streamRevealQueue.clear();
    _voiceAutoSendTimer?.cancel();
    _draftSaveTimer?.cancel();
    unawaited(_persistDraft(_controller.text));
    _controller.removeListener(_queueDraftSave);
    _scrollController.removeListener(_handleScrollChange);
    _controller.dispose();
    _composerFocusNode.dispose();
    _scrollController.dispose();
    _streamingText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isWideDesktop = widget.persistentSidebar;
    return DropTarget(
      onDragDone: _handleDroppedFiles,
      onDragEntered: (_) {
        if (mounted) setState(() => _draggingFiles = true);
      },
      onDragExited: (_) {
        if (mounted) setState(() => _draggingFiles = false);
      },
      child: Column(
        children: [
          if (_draggingFiles)
            Container(
              width: double.infinity,
              color: GamaColors.accentSoft,
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Text(
                'Solte os arquivos para anexá-los',
                textAlign: TextAlign.center,
                style: TextStyle(color: GamaColors.accentBright, fontSize: 12),
              ),
            ),
          // App bar
          Container(
            decoration: BoxDecoration(
              color: GamaColors.surface,
              border: Border(
                bottom: BorderSide(color: GamaColors.divider, width: 1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      // O acesso ao histórico permanece visível, como no layout original.
                      // O Builder garante que o botão encontre o Scaffold que contém o drawer.
                      if (!isWideDesktop)
                        Builder(
                          builder: (drawerContext) => IconButton(
                            tooltip: 'Abrir conversas',
                            style: IconButton.styleFrom(
                              backgroundColor: GamaColors.surfaceCard,
                              foregroundColor: GamaColors.textPrimary,
                              minimumSize: const Size(42, 42),
                              padding: EdgeInsets.zero,
                            ),
                            icon: const Icon(Icons.menu_rounded, size: 21),
                            onPressed: () =>
                                Scaffold.of(drawerContext).openDrawer(),
                          ),
                        ),
                      if (!isWideDesktop) const SizedBox(width: 7),
                      Container(
                        width: 32,
                        height: 32,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              GamaColors.surfaceHover,
                              GamaColors.surfaceCard,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: GamaColors.border),
                        ),
                        child: Image.asset(
                          'assets/images/image3.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.auto_awesome_rounded,
                            color: GamaColors.accent,
                            size: 22,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Os outros controles permanecem no menu de três pontos.
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Gama 2.0',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: GamaColors.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Selecionar modelo',
                        onSelected: (model) async {
                          await SettingsService.instance.setModel(model);
                          if (mounted) setState(() {});
                        },
                        itemBuilder: (context) => _chatModels
                            .map(
                              (model) => PopupMenuItem<String>(
                                value: model,
                                child: Row(
                                  children: [
                                    Icon(
                                      model == SettingsService.instance.model
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_off,
                                      size: 18,
                                      color:
                                          model ==
                                              SettingsService.instance.model
                                          ? GamaColors.accent
                                          : GamaColors.textMuted,
                                    ),
                                    const SizedBox(width: 9),
                                    Expanded(
                                      child: Text(AppConstants.labelFor(model)),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 7,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 170,
                                ),
                                child: Text(
                                  AppConstants.labelFor(
                                    SettingsService.instance.model,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: GamaColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 17,
                              ),
                            ],
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Mais opções',
                        icon: const Icon(Icons.more_vert_rounded, size: 24),
                        onSelected: (action) async {
                          switch (action) {
                            case 'history':
                              Scaffold.of(context).openDrawer();
                              break;
                            case 'voice':
                              _toggleVoiceConversation();
                              break;
                            case 'stop':
                              _stopGeneration();
                              break;
                            case 'settings':
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const SettingsScreen(),
                                ),
                              );
                              break;
                            case 'clear':
                              _clearCurrentConversation();
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          if (!isWideDesktop)
                            const PopupMenuItem(
                              value: 'history',
                              child: ListTile(
                                dense: true,
                                leading: Icon(Icons.menu_rounded),
                                title: Text('Conversas e histórico'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          PopupMenuItem(
                            value: 'voice',
                            child: ListTile(
                              dense: true,
                              leading: Icon(
                                _voiceConversationMode
                                    ? Icons.headset_mic_rounded
                                    : Icons.headset_rounded,
                              ),
                              title: Text(
                                _voiceConversationMode
                                    ? 'Interromper conversa por voz'
                                    : 'Iniciar conversa por voz',
                              ),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          if (_isLoading || _isSpeaking)
                            const PopupMenuItem(
                              value: 'stop',
                              child: ListTile(
                                dense: true,
                                leading: Icon(Icons.stop_rounded),
                                title: Text('Parar geração/áudio'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          const PopupMenuItem(
                            value: 'settings',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.settings_outlined),
                              title: Text('Configurações'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'clear',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.delete_outline_rounded),
                              title: Text('Limpar conversa'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Messages
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _messages.isEmpty
                      ? _EmptyState(
                          onSuggestion: (text) {
                            if (text == 'Revisar meu projeto (ZIP/GitHub)') {
                              _controller.text = 'Revise meu projeto e destaque problemas e melhorias.';
                              _showAttachMenu();
                              return;
                            }
                            if (text == 'Explicar este erro') {
                              _controller.text = 'Explique este erro:\n';
                              _composerFocusNode.requestFocus();
                              return;
                            }
                            _controller.text = 'Gere um widget Flutter para: ';
                            _composerFocusNode.requestFocus();
                          },
                        )
                      : NotificationListener<ScrollNotification>(
                          onNotification: _handleListScrollNotification,
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(16, 22, 16, 26),
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              final msg = _messages[index];
                              final isUser = msg.isUser;
                              final isLastAssistant =
                                  !isUser && index == _messages.length - 1;

                              return RepaintBoundary(
                                key: _messageKeys.putIfAbsent(
                                  msg.id,
                                  () => GlobalKey(),
                                ),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 760,
                                    ),
                                    child: Align(
                                      alignment: isUser
                                          ? Alignment.centerRight
                                          : Alignment.centerLeft,
                                      child: Column(
                                        crossAxisAlignment: isUser
                                            ? CrossAxisAlignment.end
                                            : CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            constraints: BoxConstraints(
                                              maxWidth: isUser ? 680 : 760,
                                            ),
                                            margin: EdgeInsets.only(
                                              bottom: isUser ? 16 : 4,
                                            ),
                                            padding: isUser
                                                ? const EdgeInsets.symmetric(
                                                    horizontal: 16,
                                                    vertical: 12,
                                                  )
                                                : EdgeInsets.zero,
                                            decoration: isUser
                                                ? BoxDecoration(
                                                    gradient: LinearGradient(
                                                      begin: Alignment.topLeft,
                                                      end:
                                                          Alignment.bottomRight,
                                                      colors: [
                                                        GamaColors
                                                            .bubbleUserSoft,
                                                        GamaColors.bubbleUser,
                                                      ],
                                                    ),
                                                    borderRadius:
                                                        const BorderRadius.only(
                                                          topLeft:
                                                              Radius.circular(
                                                                22,
                                                              ),
                                                          topRight:
                                                              Radius.circular(
                                                                22,
                                                              ),
                                                          bottomLeft:
                                                              Radius.circular(
                                                                22,
                                                              ),
                                                          bottomRight:
                                                              Radius.circular(
                                                                7,
                                                              ),
                                                        ),
                                                    border: Border.all(
                                                      color: GamaColors.accent
                                                          .withOpacity(0.20),
                                                    ),
                                                  )
                                                : null,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (!isUser &&
                                                    msg.id ==
                                                        _failedAssistantMessageId &&
                                                    _chatErrorMessage !=
                                                        null) ...[
                                                  if (msg.content
                                                      .trim()
                                                      .isNotEmpty)
                                                    MessageContentView(
                                                      content: msg.content,
                                                      isUser: false,
                                                      onTapLink: _openLink,
                                                    ),
                                                  const SizedBox(height: 8),
                                                  ChatStatusIndicator(
                                                    label: _chatErrorMessage!,
                                                    isError: true,
                                                    onRetry: _isLoading
                                                        ? null
                                                        : _retryLastFailedRequest,
                                                  ),
                                                ] else if (msg
                                                        .content
                                                        .isEmpty &&
                                                    !isUser &&
                                                    _isLoading &&
                                                    !_firstTokenReceived)
                                                  ChatStatusIndicator(
                                                    label: _chatStatusLabel,
                                                  )
                                                else if (msg.content.isEmpty &&
                                                    !isUser &&
                                                    _isLoading &&
                                                    _voiceResponsePending)
                                                  const SizedBox.shrink()
                                                else if (!isUser &&
                                                    isLastAssistant &&
                                                    _isLoading &&
                                                    !_voiceResponsePending &&
                                                    _firstTokenReceived)
                                                  ValueListenableBuilder<
                                                    String
                                                  >(
                                                    valueListenable:
                                                        _streamingText,
                                                    builder:
                                                        (
                                                          context,
                                                          content,
                                                          _,
                                                        ) => Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            MessageContentView(
                                                              content: content,
                                                              isUser: false,
                                                              onTapLink:
                                                                  _openLink,
                                                            ),
                                                            const _StreamingCursor(),
                                                          ],
                                                        ),
                                                  )
                                                else
                                                  MemoizedMessageContentView(
                                                    content: msg.content,
                                                    isUser: isUser,
                                                    onTapLink: _openLink,
                                                  ),
                                                if (!isUser &&
                                                    (_artifactsByMessageId[msg
                                                                .id]
                                                            ?.isNotEmpty ??
                                                        false)) ...[
                                                  const SizedBox(height: 12),
                                                  _ArtifactStatusList(
                                                    artifacts:
                                                        _artifactsByMessageId[msg
                                                            .id]!,
                                                    onDownload: (artifact) {
                                                      final id =
                                                          artifact['artifact_id']
                                                              ?.toString() ??
                                                          '';
                                                      final filename =
                                                          artifact['filename']
                                                              ?.toString() ??
                                                          'gamma_arquivo.zip';
                                                      if (id.isNotEmpty) {
                                                        _downloadGeneratedArtifact(
                                                          id,
                                                          filename,
                                                        );
                                                      }
                                                    },
                                                  ),
                                                ],
                                                if (!isUser &&
                                                    (_sourcesByMessageId[msg.id]
                                                            ?.isNotEmpty ??
                                                        false))
                                                  _sourceChips(msg.id),
                                                if (!isUser &&
                                                    !_isLoading &&
                                                    msg.variants.length > 1)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 8,
                                                        ),
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        IconButton(
                                                          tooltip:
                                                              'Versão anterior',
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          constraints:
                                                              const BoxConstraints.tightFor(
                                                                width: 32,
                                                                height: 32,
                                                              ),
                                                          padding:
                                                              EdgeInsets.zero,
                                                          onPressed:
                                                              msg.selectedVariantIndex >
                                                                  0
                                                              ? () => _selectResponseVariant(
                                                                  msg,
                                                                  msg.selectedVariantIndex -
                                                                      1,
                                                                )
                                                              : null,
                                                          icon: const Icon(
                                                            Icons
                                                                .chevron_left_rounded,
                                                            size: 20,
                                                          ),
                                                        ),
                                                        Text(
                                                          '${msg.selectedVariantIndex + 1}/${msg.variants.length}',
                                                          style: TextStyle(
                                                            color: GamaColors
                                                                .textMuted,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                        IconButton(
                                                          tooltip:
                                                              'Próxima versão',
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          constraints:
                                                              const BoxConstraints.tightFor(
                                                                width: 32,
                                                                height: 32,
                                                              ),
                                                          padding:
                                                              EdgeInsets.zero,
                                                          onPressed:
                                                              msg.selectedVariantIndex <
                                                                  msg
                                                                          .variants
                                                                          .length -
                                                                      1
                                                              ? () => _selectResponseVariant(
                                                                  msg,
                                                                  msg.selectedVariantIndex +
                                                                      1,
                                                                )
                                                              : null,
                                                          icon: const Icon(
                                                            Icons
                                                                .chevron_right_rounded,
                                                            size: 20,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          if (msg.content.trim().isNotEmpty)
                                            _messageActions(
                                              msg,
                                              index,
                                              isLastAssistant,
                                            ),
                                          if (!isUser)
                                            const SizedBox(height: 12),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
                if (_showScrollToBottom)
                  Positioned(
                    right: 16,
                    bottom: 14,
                    child: AnimatedOpacity(
                      opacity: _showScrollToBottom ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: FloatingActionButton.small(
                        heroTag: 'gama_scroll_to_bottom',
                        tooltip: 'Ir para o fim da conversa',
                        backgroundColor: GamaColors.surfaceElevated,
                        foregroundColor: GamaColors.accentBright,
                        onPressed: () {
                          _followStream = true;
                          _scrollToBottom(force: true);
                        },
                        child: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Anexos pendentes
          if (_processingAttachment)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: GamaColors.accentSoft,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: GamaColors.accent.withOpacity(0.35)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: GamaColors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _processingLabel ?? 'Processando anexo…',
                      style: TextStyle(
                        color: GamaColors.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_attachments.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              color: GamaColors.surface,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _attachments.map((a) {
                  if (a.kind.name == 'image' && a.sourcePath != null) {
                    return Container(
                      width: 220,
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: GamaColors.surfaceCard,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: GamaColors.border),
                      ),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => _showPendingImagePreview(a),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                File(a.sourcePath!),
                                width: 56,
                                height: 56,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 56,
                                  height: 56,
                                  color: GamaColors.surfaceHover,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => _showPendingImagePreview(a),
                              child: Text(
                                a.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: GamaColors.textPrimary,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remover anexo',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                setState(() => _attachments.remove(a)),
                            icon: const Icon(Icons.close_rounded, size: 17),
                            constraints: const BoxConstraints.tightFor(
                              width: 28,
                              height: 32,
                            ),
                            padding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    );
                  }
                  return Container(
                    padding: const EdgeInsets.only(left: 4, right: 4),
                    decoration: BoxDecoration(
                      color: GamaColors.surfaceCard,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: GamaColors.border),
                    ),
                    child: Chip(
                      avatar: CircleAvatar(
                        backgroundColor: GamaColors.accentSoft,
                        child: Icon(
                          a.kind.name == 'image'
                              ? Icons.image_rounded
                              : a.kind.name == 'video'
                              ? Icons.movie_creation_outlined
                              : a.kind.name == 'zip'
                              ? Icons.folder_zip_rounded
                              : a.kind.name == 'pdf'
                              ? Icons.picture_as_pdf_rounded
                              : Icons.insert_drive_file_rounded,
                          size: 16,
                          color: GamaColors.accent,
                        ),
                      ),
                      label: Text(
                        a.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: GamaColors.textPrimary,
                        ),
                      ),
                      backgroundColor: Colors.transparent,
                      side: BorderSide.none,
                      deleteIcon: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: GamaColors.textMuted,
                      ),
                      onDeleted: () {
                        setState(() => _attachments.remove(a));
                      },
                    ),
                  );
                }).toList(),
              ),
            ),

          // Input
          ChatComposer(
            controller: _controller,
            focusNode: _composerFocusNode,
            isLoading: _isLoading || _waitingForAttachment,
            isListening: _isListening,
            mode: _mode,
            onAttach: _showAttachMenu,
            onToggleListen: _toggleListen,
            onSend: _sendMessage,
            onSpeakSend: _toggleVoiceConversation,
            onPasteImage: _pasteClipboardContent,
            onStop: _stopGeneration,
            onModeChanged: (m) async {
              setState(() => _mode = m);
              await SettingsService.instance.setMode(m);
            },
          ),
        ],
      ),
    );
  }
}

class _ArtifactStatusList extends StatelessWidget {
  final List<Map<String, dynamic>> artifacts;
  final ValueChanged<Map<String, dynamic>> onDownload;

  const _ArtifactStatusList({
    required this.artifacts,
    required this.onDownload,
  });

  String _validationLabel(Map<String, dynamic> validation) {
    switch (validation['status']?.toString()) {
      case 'passed':
        return 'Validação sintática passou nos formatos suportados';
      case 'partial':
        return 'Validação sintática parcial';
      case 'issues_found':
        return 'Foram encontrados problemas de validação';
      case 'not_checked':
        return 'Código não verificado sintaticamente';
      case 'no_source_files':
        return 'Nenhum arquivo-fonte reconhecido para validação';
      case 'invalid_archive':
        return 'O arquivo não passou na validação estrutural';
      default:
        return 'Validação de código não disponível';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: artifacts
          .map((artifact) {
            final filename =
                artifact['filename']?.toString() ?? 'arquivo gerado';
            final kind = artifact['kind']?.toString() ?? 'zip';
            final structural = artifact['validation'] is Map
                ? Map<String, dynamic>.from(artifact['validation'] as Map)
                : <String, dynamic>{};
            final source = artifact['source_validation'] is Map
                ? Map<String, dynamic>.from(
                    artifact['source_validation'] as Map,
                  )
                : <String, dynamic>{};
            final isZip = kind == 'zip';
            final isVideo = kind == 'video';
            final providerCost = double.tryParse(
              artifact['provider_cost_usd']?.toString() ?? '',
            );
            final videoAudioLabel = artifact['audio_generated'] == false
                ? 'sem áudio'
                : 'com áudio';
            final zipOk = structural['ok'] == true;
            final syntaxStatus = source['status']?.toString() ?? '';
            final checked = source['checked_count']?.toString() ?? '0';
            final unverified = source['unverified_count']?.toString() ?? '0';
            final issues = source['issue_count']?.toString() ?? '0';

            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: GamaColors.surfaceCard.withOpacity(0.82),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: GamaColors.borderSoft),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isZip
                            ? Icons.folder_zip_outlined
                            : isVideo
                            ? Icons.movie_outlined
                            : Icons.description_outlined,
                        color: GamaColors.accentBright,
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          filename,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GamaColors.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (isZip) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          zipOk
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 16,
                          color: zipOk
                              ? GamaColors.accentBright
                              : Colors.orangeAccent,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            zipOk
                                ? 'Integridade do ZIP: passou (estrutura/CRC)'
                                : 'Integridade do ZIP: falhou',
                            style: TextStyle(
                              color: GamaColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          syntaxStatus == 'passed'
                              ? Icons.verified_outlined
                              : syntaxStatus == 'issues_found'
                              ? Icons.warning_amber_rounded
                              : Icons.info_outline_rounded,
                          size: 16,
                          color: syntaxStatus == 'issues_found'
                              ? Colors.orangeAccent
                              : GamaColors.accentBright,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _validationLabel(source),
                            style: TextStyle(
                              color: GamaColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (source.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        'Arquivos verificados: $checked · não verificados: $unverified · problemas: $issues',
                        style: TextStyle(
                          color: GamaColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                      if (source['note'] is String)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            source['note'].toString(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: GamaColors.textMuted,
                              fontSize: 10.5,
                            ),
                          ),
                        ),
                    ],
                  ] else if (isVideo) ...[
                    Text(
                      'Vídeo gerado${artifact['duration_seconds'] == null ? '' : ' · ${artifact['duration_seconds']} s'}${artifact['resolution'] == null ? '' : ' · ${artifact['resolution']}'} · $videoAudioLabel',
                      style: TextStyle(
                        color: GamaColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Confira o resultado antes de compartilhar ou substituir o original.',
                      style: TextStyle(
                        color: GamaColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    if (providerCost != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Custo informado pela OpenRouter: US\$${providerCost.toStringAsFixed(4)}',
                        style: TextStyle(
                          color: GamaColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ] else ...[
                    Text(
                      structural['ok'] == true
                          ? 'Arquivo gerado e validado estruturalmente.'
                          : 'O arquivo precisa de verificação adicional.',
                      style: TextStyle(
                        color: GamaColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => onDownload(artifact),
                      icon: const Icon(Icons.download_rounded, size: 16),
                      label: const Text('Baixar arquivo'),
                    ),
                  ),
                ],
              ),
            );
          })
          .toList(growable: false),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ValueChanged<String> onSuggestion;

  const _EmptyState({required this.onSuggestion});

  static const _suggestions = [
    'Revisar meu projeto (ZIP/GitHub)',
    'Explicar este erro',
    'Gerar um widget Flutter',
  ];
  static const _suggestionTitles = [
    'Revisar meu projeto',
    'Explicar este erro',
    'Gerar um widget Flutter',
  ];
  static const _suggestionDescriptions = [
    'Anexe um ZIP ou cole um link do GitHub.',
    'Cole uma mensagem de erro para entender o que ocorreu.',
    'Descreva o componente que você quer construir.',
  ];
  static const _suggestionIcons = [
    Icons.code_rounded,
    Icons.lightbulb_outline_rounded,
    Icons.psychology_alt_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 94,
                height: 94,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [GamaColors.surfaceHover, GamaColors.surfaceCard],
                  ),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: GamaColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: GamaColors.accent.withOpacity(0.12),
                      blurRadius: 36,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Image.asset(
                  'assets/images/image3.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: GamaColors.surfaceCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: GamaColors.borderSoft),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: GamaColors.success, size: 7),
                    SizedBox(width: 7),
                    Text(
                      'SEU ESPAÇO DE TRABALHO',
                      style: TextStyle(
                        color: GamaColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              Text(
                'O que vamos criar hoje?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GamaColors.textPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.8,
                  height: 1.12,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Converse, programe ou explore uma ideia.\nA Gama ajuda você a dar o próximo passo.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GamaColors.textMuted,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 27),
              ..._suggestions.asMap().entries.map((entry) {
                final index = entry.key;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: GamaColors.surfaceCard,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      onTap: () => onSuggestion(entry.value),
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(13, 13, 14, 13),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: GamaColors.borderSoft),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: GamaColors.accentSoft,
                                borderRadius: BorderRadius.circular(13),
                              ),
                              child: Icon(
                                _suggestionIcons[index],
                                color: GamaColors.accentBright,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _suggestionTitles[index],
                                    style: TextStyle(
                                      color: GamaColors.textPrimary,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _suggestionDescriptions[index],
                                    style: TextStyle(
                                      color: GamaColors.textMuted,
                                      fontSize: 11.5,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_rounded,
                              color: GamaColors.textMuted,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 560),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 0.2, end: 1).animate(_controller),
    child: Text(
      '▍',
      style: TextStyle(color: GamaColors.accentBright, fontSize: 17),
    ),
  );
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_c.value + i * 0.2) % 1.0;
            final opacity =
                0.3 + 0.7 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: GamaColors.accent.withOpacity(0.85),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
