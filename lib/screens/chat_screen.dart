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

import '../core/gama_page_route.dart';
import '../core/gama_colors.dart';
import 'voice_mode_screen.dart';
import '../core/design_tokens.dart';
import '../core/constants.dart';
import '../core/image_reference_intent.dart';
import '../models/message.dart';
import '../models/oficina_kind.dart';
import '../services/attachment_service.dart';
import '../services/conversation_service.dart';
import '../services/conversation_sync_service.dart';
import '../services/memory_service.dart';
import '../services/ollama_service.dart';
import 'library_screen.dart';
import 'settings_screen.dart';
import '../widgets/message_content.dart';
import '../widgets/chat_status_indicator.dart';
import '../widgets/chat_composer.dart';
import '../widgets/artifact_status_list.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_skeleton.dart';
import '../services/settings_service.dart';
import '../services/download_service.dart';
import '../utils/message_sanitize.dart';
import '../services/tts_service.dart';
import '../services/plugin_settings_service.dart';
import '../services/identity_service.dart';
import 'oficina_screen.dart';
import '../utils/error_logger.dart';
import '../utils/speech_recovery_policy.dart';
import '../utils/generation_session.dart';
import '../utils/chat_history_window.dart';
import '../utils/chat_scroll_policy.dart';
import '../utils/chat_generation_clock.dart';
import '../utils/stream_display_filter.dart';
import '../utils/speech_reveal_buffer.dart';
import 'package:flutter/rendering.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final bool persistentSidebar;

  /// Quando definido, a conversa opera em modo Oficina (criação focada).
  final OficinaKind? oficinaKind;
  final String? initialPrompt;

  /// Optional, read-only reference for the Oficina's code review.
  final String? codeComparisonBase;
  final String? codeComparisonLanguage;

  const ChatScreen({
    super.key,
    required this.conversationId,
    this.persistentSidebar = false,
    this.oficinaKind,
    this.initialPrompt,
    this.codeComparisonBase,
    this.codeComparisonLanguage,
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
  // Paginação de apresentação: mantém todas as mensagens no Hive e na API.
  final ChatHistoryWindow _historyWindow = ChatHistoryWindow();
  String? _newMessageAnimationId;
  Timer? _clearMessagesTimer;
  final ChatGenerationClock _generationClock = ChatGenerationClock();
  Duration get _generationElapsed => _generationClock.value;
  String _imageAspectRatio = '1:1';
  String _imageStyle = 'Automático';
  int _videoDuration = 5;
  String _videoResolution = '480p';
  String _videoAspectRatio = '16:9';
  bool _videoGenerateAudio = true;
  String? _beforeImagePath;
  bool _isLoading = false;
  String _streamPhase = '';
  final Map<String, List<Map<String, dynamic>>> _artifactsByMessageId = {};
  final Map<String, String> _videoPathsByArtifactId = {};
  DateTime? _lastAutoScrollAt;
  bool _scrollCallbackScheduled = false;
  bool _pendingForceScroll = false;
  bool _showScrollToBottom = false;
  final ValueNotifier<String> _streamingText = ValueNotifier<String>('');
  final ValueNotifier<String> _voiceReplyDisplayedText = ValueNotifier<String>(
    '',
  );
  String? _voiceReplyDisplayMessageId;
  final Queue<int> _streamRevealQueue = Queue<int>();
  StringBuffer _streamDisplayedBuffer = StringBuffer();
  bool _streamPreviewTruncated = false;
  final SpeechRevealBuffer _speechReveal = SpeechRevealBuffer();
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  Timer? _streamRevealTimer;
  DateTime? _streamRevealLastFrame;
  double _streamRevealBudget = 0;
  bool _finishingStreamReveal = false;
  String _streamRevealFinalText = '';
  DateTime? _streamRevealFinishStarted;
  bool _messageKeyPruneScheduled = false;
  StringBuffer _streamRawText = StringBuffer();
  final GamaStreamDisplayFilter _streamDisplayFilter = GamaStreamDisplayFilter();
  String _streamSearchQuery = '';
  bool _followStream = true;
  Timer? _voiceAutoSendTimer;
  Timer? _draftSaveTimer;
  bool _restoringDraft = false;
  bool _draggingFiles = false;
  bool _voiceConversationMode = false;
  double _voiceSoundLevel = 0;
  bool _voiceMutedByUser = false;

  /// Mantém a tela de voz acoplada ao STT/TTS existente, sem duplicar sessão.
  Future<void> _openVoiceMode() async {
    if (widget.oficinaKind != null) return;
    if (!_voiceConversationMode) await _toggleVoiceConversation();
    if (!mounted || !_voiceConversationMode) return;
    try {
      await Navigator.of(context).push<void>(
        GamaPageRoute<void>(
          builder: (_) => VoiceModeScreen(
            isListening: () => _micArmed && _isListening,
            isReconnecting: () => _micArmed && !_isListening,
            isSpeaking: () => _isSpeaking,
            isPreparingSpeech: () =>
                !_isSpeaking && !_isLoading && TtsService.instance.isBusy,
            isProcessing: () => _isLoading,
            soundLevel: () => _voiceSoundLevel,
            transcript: () =>
                (_isSpeaking || _isLoading) &&
                    _voiceReplyDisplayedText.value.isNotEmpty
                ? _voiceReplyDisplayedText.value
                : _controller.text,
            onToggleMic: _toggleVoiceMicrophone,
            onInterrupt: _toggleVoiceConversation,
          ),
        ),
      );
    } finally {
      if (mounted && _voiceConversationMode) {
        await _toggleVoiceConversation();
      }
    }
  }

  bool _titleGenerationInProgress = false;
  final Map<String, List<Map<String, dynamic>>> _sourcesByMessageId = {};
  final Map<String, List<String>> _activityByMessageId = {};
  final Set<String> _truncatedMessageIds = <String>{};
  final Map<String, int> _feedbackByMessageId = {};
  StreamSubscription<ChatStreamEvent>? _streamSubscription;
  Future<void>? _assistantPersistence;
  // Cada geração recebe um token de sessão: callbacks de streams cancelados
  // nunca devem finalizar ou sobrescrever uma geração mais recente.
  final GenerationSession _generation = GenerationSession();

  /// Arquivos anexados (ainda não enviados)
  final List<ProcessedAttachment> _attachments = [];

  /// True enquanto um anexo (esp. ZIP) está sendo processado/indexado.
  bool _processingAttachment = false;
  bool _showSlashSuggestions = false;
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
  Timer? _speechRestartTimer;
  final SpeechRecoveryPolicy _speechRecovery = SpeechRecoveryPolicy();

  GamaMode _mode = GamaMode.programar;
  bool _speakNextReply = false;
  bool _ttsEarlyStarted = false;
  StreamingSpeechSession? _liveSpeech;
  final List<Future<void>> _pendingGeneratedImages = <Future<void>>[];
  bool _isSpeaking = false;
  int _manualSpeechEpoch = 0;
  String? _failedAssistantMessageId;
  String? _chatErrorMessage;
  bool _failedRequestRetryable = true;
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
    SettingsService.instance.addListener(_onModeSettingsChanged);
    if (widget.initialPrompt != null) _controller.text = widget.initialPrompt!;
    _loadMessages();
    _controller.addListener(_queueDraftSave);
    _controller.addListener(_updateSlashSuggestions);
    unawaited(_restoreDraft());
    _initSpeech();
    _scrollController.addListener(_handleScrollChange);
    unawaited(_loadFeedback());
  }

  void _onModeSettingsChanged() {
    if (!mounted || widget.oficinaKind != null) return;
    final selected = SettingsService.instance.mode;
    if (_mode != selected) setState(() => _mode = selected);
  }

  void _updateSlashSuggestions() {
    final show = _controller.text.startsWith('/') && !_isLoading;
    if (show != _showSlashSuggestions && mounted) {
      setState(() => _showSlashSuggestions = show);
    }
  }

  void _selectSlashCommand(String command) {
    _controller.value = TextEditingValue(
      text: command,
      selection: TextSelection.collapsed(offset: command.length),
    );
    _composerFocusNode.requestFocus();
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
    } catch (error, stack) {
      logSwallowed(error, stack);
    }
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
    } catch (error, stack) {
      logSwallowed(error, stack);
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
    } catch (error, stack) {
      logSwallowed(error, stack);
    }
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
    } catch (error, stack) {
      logSwallowed(error, stack);
    }
  }

  void _handleScrollChange() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final nearBottom = ChatScrollPolicy.nearEnd(
      position.pixels, position.maxScrollExtent,
    );
    _nearBottomCache = nearBottom;
    if (nearBottom && (_isLoading || _isSpeaking)) _followStream = true;
    final show = !nearBottom;
    if (show == _showScrollToBottom) return;
    _showScrollToBottom = show;
    if (mounted) setState(() {});
  }

  bool _nearBottomCache = true;

  bool _handleListScrollNotification(ScrollNotification notification) {
    // Touch drag, mouse wheel e trackpad devem interromper o auto-follow.
    // Scroll programático para o fim não é uma interação do usuário.
    final userDragging = notification is ScrollStartNotification &&
        notification.dragDetails != null;
    final userMovingUp = notification is UserScrollNotification &&
        notification.direction == ScrollDirection.forward;
    if ((_isLoading || _isSpeaking) && (userDragging || userMovingUp)) {
      _followStream = false;
    }
    return false;
  }

  void _loadEarlierMessages() {
    final total = _messages.length;
    if (!_historyWindow.hasOlder(total)) return;
    final position = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final previousOffset = position?.pixels ?? 0.0;
    final previousMax = position?.maxScrollExtent ?? 0.0;
    _followStream = false;
    setState(() => _historyWindow.loadEarlier(total));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final updated = _scrollController.position;
      _scrollController.jumpTo(ChatScrollPolicy.restoredOffset(
        oldOffset: previousOffset,
        oldMaxExtent: previousMax,
        newMaxExtent: updated.maxScrollExtent,
        minExtent: updated.minScrollExtent,
      ));
    });
  }

  // Mantém somente uma janela de prévia em memória de renderização.
  // O conteúdo integral permanece em _streamRawText e é salvo ao finalizar.
  // Assim, o custo por frame não cresce com respostas de 20 ou 100 mil chars.
  void _publishStreamPreview() {
    const maxPreview = 16000;
    if (_streamDisplayedBuffer.length > maxPreview) {
      final text = _streamDisplayedBuffer.toString();
      var start = text.length - maxPreview;
      if (start < text.length &&
          text.codeUnitAt(start) >= 0xDC00 &&
          text.codeUnitAt(start) <= 0xDFFF) {
        start++;
      }
      _streamDisplayedBuffer = StringBuffer(text.substring(start));
      _streamPreviewTruncated = true;
    }
    final visible = _streamDisplayedBuffer.toString();
    _streamingText.value = _streamPreviewTruncated
        ? '… [prévia anterior ocultada durante a geração]\n\n$visible'
        : visible;
  }

  // Revelação adaptativa a cada ~frame, limitada pelo tempo efetivamente
  // decorrido. A fila é por code point: não quebra pares UTF-16/emoji.
  // O texto original e a persistência não são modificados por este efeito.
  void _queueStreamText(String text) {
    _streamRawText.write(text);
    // Ferramentas retornam blocos internos grandes ([[GAMA_FILES]], base64).
    // Eles precisam ser salvos, mas jamais renderizados como texto no chat.
    final visible = _streamDisplayFilter.append(text);
    if (visible.isEmpty) return;
    // Opção do sistema para reduzir movimento (TalkBack/acessibilidade).
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _streamRevealTimer?.cancel();
      _streamRevealTimer = null;
      _streamRevealLastFrame = null;
      _streamRevealBudget = 0;
      final pending = String.fromCharCodes(_streamRevealQueue);
      _streamRevealQueue.clear();
      _streamDisplayedBuffer.write(pending);
      _streamDisplayedBuffer.write(visible);
      _publishStreamPreview();
      if (_followStream) _scrollToBottom(followStream: true);
      return;
    }

    _streamRevealQueue.addAll(visible.runes);
    if (_streamRevealTimer == null) {
      _streamRevealLastFrame = DateTime.now();
      _streamRevealBudget = 0;
      _streamRevealTimer = Timer.periodic(
        const Duration(milliseconds: 48),
        _revealStreamFrame,
      );
    }
  }

  void _revealStreamFrame(Timer timer) {
    if (!mounted || _streamRevealQueue.isEmpty) {
      timer.cancel();
      _streamRevealTimer = null;
      _streamRevealLastFrame = null;
      _streamRevealBudget = 0;
      if (_finishingStreamReveal && mounted) {
        _streamDisplayedBuffer = StringBuffer();
        _streamPreviewTruncated = false;
        _streamingText.value = _streamRevealFinalText;
        setState(() => _finishingStreamReveal = false);
        if (_followStream) _scrollToBottom(followStream: true);
      }
      return;
    }
    final now = DateTime.now();
    final elapsed = now
        .difference(_streamRevealLastFrame ?? now)
        .inMicroseconds;
    _streamRevealLastFrame = now;
    // Mantém movimento constante em 60/90/120 Hz e após frames atrasados.
    final seconds = (elapsed / 1000000).clamp(0.0, 0.050).toDouble();
    final pending = _streamRevealQueue.length;
    final charsPerSecond = pending > 650
        ? 390.0
        : pending > 260
        ? 260.0
        : pending > 80
        ? 170.0
        : 92.0;
    _streamRevealBudget += seconds * charsPerSecond;
    // Ao concluir a requisição, drena a fila em até ~450 ms, mantendo
    // a animação visível em vez de substituir todo o texto de uma vez.
    final elapsedFinish = _streamRevealFinishStarted == null ? 0 :
        now.difference(_streamRevealFinishStarted!).inMilliseconds;
    final finishFrames = ((450 - elapsedFinish).clamp(48, 450) / 48).ceil();
    final minimumFinishCount = _finishingStreamReveal
        ? (pending / finishFrames).ceil()
        : 0;
    final count = _finishingStreamReveal
        ? _streamRevealBudget.floor().clamp(minimumFinishCount, pending).toInt()
        : _streamRevealBudget.floor().clamp(0, 24).toInt();
    if (count == 0) return;
    _streamRevealBudget -= count;
    final next = StringBuffer();
    for (var i = 0; i < count && _streamRevealQueue.isNotEmpty; i++) {
      next.writeCharCode(_streamRevealQueue.removeFirst());
    }
    _streamDisplayedBuffer.write(next);
    _publishStreamPreview();
    if (_followStream) _scrollToBottom(followStream: true);
  }

  void _finishStreamReveal(String finalText, {bool animate = false}) {
    if (animate && mounted && _streamRevealQueue.isNotEmpty &&
        !(MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
      _streamRevealFinalText = finalText;
      _streamRevealFinishStarted = DateTime.now();
      setState(() => _finishingStreamReveal = true);
      return;
    }
    _finishingStreamReveal = false;
    _streamRevealFinishStarted = null;
    _streamRevealTimer?.cancel();
    _streamRevealTimer = null;
    _streamRevealLastFrame = null;
    _streamRevealBudget = 0;
    _streamRevealQueue.clear();
    _streamDisplayedBuffer = StringBuffer();
    _streamPreviewTruncated = false;
    if (mounted) _streamingText.value = finalText;
  }

  // Conserva chaves visíveis e das mensagens mais recentes. Mensagens antigas
  // recebem uma chave novamente quando o ListView precisa montá-las.
  GlobalKey _messageKeyFor(String messageId) {
    final key = _messageKeys.putIfAbsent(messageId, () => GlobalKey());
    if (_messageKeys.length > 140 && !_messageKeyPruneScheduled) {
      _messageKeyPruneScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _messageKeyPruneScheduled = false;
        if (mounted) _pruneMessageKeys();
      });
    }
    return key;
  }

  void _pruneMessageKeys() {
    if (_messageKeys.length <= 120) return;
    final recentStart = _messages.length > 80 ? _messages.length - 80 : 0;
    final recent = _messages.skip(recentStart).map((m) => m.id).toSet();
    _messageKeys.removeWhere(
      (id, key) => !recent.contains(id) && key.currentContext == null,
    );
  }

  void _scrollToMessageTop(String messageId) {
    final key = _messageKeyFor(messageId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = key.currentContext;
      if (!mounted || target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.02,
        duration: (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
            ? Duration.zero
            : const Duration(milliseconds: 220),
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
    final isUntitled =
        conversation != null &&
        (conversation.title == 'Nova conversa' ||
            (widget.oficinaKind != null &&
                conversation.title == widget.oficinaKind!.conversationTitle));
    if (conversation == null || !isUntitled) return;
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
        if (latest != null &&
            (latest.title == 'Nova conversa' ||
                (widget.oficinaKind != null &&
                    latest.title == widget.oficinaKind!.conversationTitle))) {
          await _service.renameConversation(widget.conversationId, title);
        }
      }
    } finally {
      _titleGenerationInProgress = false;
    }
  }

  Future<void> _continueResponse() async {
    if (_isLoading) return;
    _controller.text = 'Continue a resposta anterior de onde parou, sem repetir o que já foi explicado.';
    await _sendMessage();
  }

  Future<void> _sendImageFollowup(String prompt) async {
    if (prompt.trim().isEmpty || _isLoading) return;
    _controller.text = prompt;
    await _sendMessage();
  }

  Future<void> _editGeneratedImage(String? path, String prompt) async {
    if (_isLoading) return;
    if (path == null || !await File(path).exists()) {
      _snack('Não encontrei a imagem anterior para editar.');
      return;
    }
    try {
      final attachment = await _attachmentService.processFile(path);
      if (!mounted) return;
      if (!attachment.isNativeImage) {
        _snack('Não consegui preparar a imagem anterior para edição.');
        return;
      }
      setState(() => _attachments.add(attachment));
    } catch (error, stack) {
      logSwallowed(error, stack);
      _snack('Não consegui anexar a imagem anterior.');
      return;
    }
    await _sendImageFollowup(prompt);
  }

  Future<void> _varyGeneratedImage(String? path, String prompt) async {
    if (path == null || !await File(path).exists()) {
      _snack('Não encontrei a imagem anterior para criar uma variação.');
      return;
    }
    try {
      final attachment = await _attachmentService.processFile(path);
      if (!mounted) return;
      if (!attachment.isNativeImage) {
        _snack('Não consegui preparar a imagem anterior para variação.');
        return;
      }
      setState(() => _attachments.add(attachment));
      await _sendImageFollowup(prompt);
    } catch (error, stack) {
      logSwallowed(error, stack);
      _snack('Não consegui usar a imagem anterior como referência.');
    }
  }

  Future<void> _submitFollowUp(String prompt) async {
    if (_isLoading) return;
    _controller.text = prompt;
    await _sendMessage();
  }

  void _startGenerationClock() => _generationClock.start();

  void _stopGenerationClock() => _generationClock.stop();

  /// Um tick do contador reconstrói somente este pequeno indicador.
  Widget _timedStreamStatus() => ValueListenableBuilder<Duration>(
    valueListenable: _generationClock,
    builder: (context, _, __) => ChatStatusIndicator(label: _streamStatusLabel),
  );

  String get _elapsedLabel {
    final seconds = _generationElapsed.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _precedingUserPrompt(int index) {
    for (var i = index - 1; i >= 0; i--) {
      if (_messages[i].isUser) return _rawUserPrompt(_messages[i]);
    }
    return '';
  }

  String? _imagePathFromContent(String content) {
    final match = RegExp(
      r'\[gama_image_file\]\s*mime:[^\n]+\s*path:([^\n]+)\s*\[/gama_image_file\]',
    ).firstMatch(content);
    return match?.group(1)?.trim();
  }

  bool _looksLikeImageEditRequest(String text) =>
      ImageReferenceIntent.requiresPreviousImage(text);

  String? _latestGeneratedImagePath() {
    for (final message in _messages.reversed) {
      if (!message.isAssistant) continue;
      final path = _imagePathFromContent(message.content);
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  Future<void> _toggleVoiceConversation() async {
    if (_voiceConversationMode && _isLoading) {
      await _stopGeneration();
      if (mounted) {
        _voiceMutedByUser = false;
        unawaited(_resumeVoiceConversation());
      }
      return;
    }
    if (_voiceConversationMode && (_isSpeaking || TtsService.instance.isBusy)) {
      // Interrupção por toque durante a reprodução: para a fala, mantém o
      // modo de voz ativo e reabre o microfone para a próxima mensagem.
      try {
        await TtsService.instance.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
      if (mounted) setState(() => _isSpeaking = false);
      _micArmed = false;
      _speechSessionId++;
      try {
        await _speech.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
      if (mounted) setState(() => _isListening = false);
      await _toggleListen();
      if (mounted && _micArmed) _snack('Resposta interrompida. Pode falar.');
      return;
    }
    if (_voiceConversationMode) {
      _voiceConversationMode = false;
      _voiceMutedByUser = false;
      _cancelSpeechRestart();
      _voiceAutoSendTimer?.cancel();
      _voiceAutoSendTimer = null;
      _micArmed = false;
      _speechSessionId++;
      _speechRestartScheduled = false;
      try {
        await _speech.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
      try {
        await TtsService.instance.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
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
    _voiceMutedByUser = false;
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

  Future<void> _toggleVoiceMicrophone() async {
    await _toggleListen();
    _voiceMutedByUser = !_micArmed;
  }

  Future<void> _sendMessageWithVoiceReply() async {
    if (_controller.text.trim().isEmpty && _attachments.isEmpty) return;
    _speakNextReply = true;
    await _sendMessage();
  }

  Future<void> _resumeVoiceConversation() async {
    if (!mounted ||
        !_voiceConversationMode ||
        _isLoading ||
        _micArmed ||
        _voiceMutedByUser)
      return;
    try {
      await _toggleListen();
    } catch (error, stack) {
      logSwallowed(error, stack);
    }
  }

  Widget _sourceChips(String messageId) {
    final sources =
        _sourcesByMessageId[messageId] ?? const <Map<String, dynamic>>[];
    if (sources.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        decoration: BoxDecoration(
          color: context.gama.surfaceCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.gama.borderSoft),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            leading: Icon(Icons.travel_explore, color: context.gama.accent),
            title: Text(
              'Fontes (${sources.length})',
              style: TextStyle(
                color: context.gama.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            children: sources.take(8).map((source) {
              final rawUrl = (source['url'] ?? source['link'] ?? '')
                  .toString()
                  .trim();
              final uri = Uri.tryParse(rawUrl);
              final domain = uri != null && uri.host.isNotEmpty
                  ? uri.host.replaceFirst(RegExp(r'^www\.'), '')
                  : (source['source'] ?? source['title'] ?? 'Fonte').toString();
              final title = (source['title'] ?? domain).toString();
              final canOpen =
                  rawUrl.startsWith('http://') || rawUrl.startsWith('https://');
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: _SourceFavicon(uri: uri),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.gama.textPrimary,
                    fontSize: 13,
                  ),
                ),
                subtitle: Text(
                  domain,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.gama.textMuted, fontSize: 12),
                ),
                trailing: canOpen
                    ? Icon(
                        Icons.open_in_new,
                        size: 16,
                        color: context.gama.textMuted,
                      )
                    : null,
                onTap: canOpen ? () => _openLink(rawUrl) : null,
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  String _citationMarkdown(String messageId, String content) {
    final sources = _sourcesByMessageId[messageId] ?? const [];
    if (sources.isEmpty || !content.contains('[')) return content;
    final chunks = content.split(RegExp(r'(```[\s\S]*?```)'));
    for (var i = 0; i < chunks.length; i++) {
      if (chunks[i].startsWith('```')) continue;
      chunks[i] = chunks[i].replaceAllMapped(
        RegExp(r'\[(\d{1,2})\](?!\s*\()'),
        (match) {
          final sourceIndex = int.tryParse(match.group(1) ?? '') ?? 0;
          if (sourceIndex < 1 || sourceIndex > sources.length) {
            return match.group(0)!;
          }
          final url = Uri.tryParse(
            sources[sourceIndex - 1]['url']?.toString() ?? '',
          );
          if (url == null || !{'http', 'https'}.contains(url.scheme)) {
            return match.group(0)!;
          }
          return '[${match.group(1)}](${url.toString()})';
        },
      );
    }
    return chunks.join();
  }

  void _showPendingImagePreview(ProcessedAttachment attachment) {
    final path = attachment.sourcePath;
    if (path == null || path.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: context.gama.surfaceElevated,
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
          if (!mounted || !_micArmed) return;
          debugPrint('speech status: $status (armed=$_micArmed)');
          if (status == 'listening') {
            _cancelSpeechRestart();
            _speechRecovery.reset();
            if (!_isListening) setState(() => _isListening = true);
          } else if (status == 'done' || status == 'notListening') {
            if (_isListening) setState(() => _isListening = false);
            // O fim normal da sessão (silêncio) não consome tentativas.
            _scheduleSpeechRestart();
          }
        },
        onError: (error) {
          debugPrint('speech error: $error');
          if (!_micArmed || !mounted) return;
          _handleSpeechFailure(permanent: error.permanent);
        },
        debugLogging: kDebugMode,
      );
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('speech init: $e');
      _speechReady = false;
    }
  }

  void _cancelSpeechRestart() {
    _speechRestartTimer?.cancel();
    _speechRestartTimer = null;
    _speechRestartScheduled = false;
  }

  void _handleSpeechFailure({required bool permanent}) {
    if (!_micArmed || !mounted) return;
    final delay = _speechRecovery.recordFailure(permanent: permanent);
    if (delay == null) {
      _cancelSpeechRestart();
      _micArmed = false;
      _speechSessionId++;
      _flushSpeechPartial();
      setState(() => _isListening = false);
      _snack(
        permanent
            ? 'O acesso ao microfone foi negado ou não está disponível. Confira as permissões e ative novamente.'
            : 'Não foi possível restabelecer o microfone. Toque para tentar novamente.',
      );
      return;
    }
    if (_isListening) setState(() => _isListening = false);
    _scheduleSpeechRestart(delay: delay, replaceExisting: true);
  }

  void _scheduleSpeechRestart({
    Duration delay = const Duration(milliseconds: 850),
    bool replaceExisting = false,
  }) {
    if (!_micArmed || !mounted) return;
    if (_speechRestartScheduled && !replaceExisting) return;
    _cancelSpeechRestart();
    _speechRestartScheduled = true;
    final sessionId = _speechSessionId;
    _speechRestartTimer = Timer(delay, () async {
      _speechRestartTimer = null;
      if (!mounted || !_micArmed || sessionId != _speechSessionId) {
        _speechRestartScheduled = false;
        return;
      }
      // O Android pode entregar o finalResult um pouco depois de "done".
      _flushSpeechPartial();
      try {
        await _speech.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
      if (!mounted || !_micArmed || sessionId != _speechSessionId) {
        _speechRestartScheduled = false;
        return;
      }
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
    } catch (e, stack) {
      logSwallowed(e, stack, context: 'reconexão de voz');
      _handleSpeechFailure(permanent: false);
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
        onSoundLevelChange: (level) {
          if (!mounted || sessionId != _speechSessionId) return;
          // Valor relativo retornado pela plataforma, não volume calibrado.
          _voiceSoundLevel = ((level + 25) / 55).clamp(0.0, 1.0).toDouble();
        },
      );
    }

    try {
      await listen();
    } catch (error, stack) {
      logSwallowed(error, stack);
      try {
        await _speech.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
      try {
        await listen();
      } catch (e, stack) {
        logSwallowed(e, stack, context: 'iniciar reconhecimento de voz');
        _handleSpeechFailure(permanent: false);
        return;
      }
    }

    if (mounted && _micArmed && sessionId == _speechSessionId) {
      // O botão pode estar armado enquanto a plataforma reconecta.
      setState(() => _isListening = _speech.isListening);
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
      _cancelSpeechRestart();
      _speechRecovery.reset();
      _flushSpeechPartial();
      try {
        await _speech.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
      if (mounted) setState(() => _isListening = false);
      return;
    }

    // Início: o texto que já estava no campo vira a base permanente.
    _speechConfirmed = _controller.text;
    _speechPartial = '';
    _speechLastFinalText = '';
    _speechSessionId++;
    _cancelSpeechRestart();
    _speechRecovery.reset();
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
      _manualSpeechEpoch++;
      _speechReveal.reset();
      _voiceReplyDisplayMessageId = null;
      _voiceReplyDisplayedText.value = '';
      unawaited(TtsService.instance.stop());
      _generation.invalidate();
      _stopGenerationClock();
      _streamSubscription?.cancel();
      _streamRevealTimer?.cancel();
      _streamRevealTimer = null;
      _streamRevealLastFrame = null;
      _streamRevealBudget = 0;
      _streamRevealQueue.clear();
      _finishingStreamReveal = false;
      _streamRevealFinishStarted = null;
      _streamRawText = StringBuffer();
      _streamDisplayFilter.reset();
      _streamDisplayedBuffer = StringBuffer();
      _streamPreviewTruncated = false;
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
      _cancelSpeechRestart();
      try {
        _speech.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
      _isListening = false;
      _loadMessages();
    }
  }

  void _loadMessages() {
    setState(() {
      _messages = _service.getMessages(widget.conversationId);
      _artifactsByMessageId.clear();
      for (final message in _messages) {
        if (message.artifacts.isNotEmpty) {
          _artifactsByMessageId[message.id] = message.artifacts;
        }
      }
      _sourcesByMessageId.clear();
      _activityByMessageId.clear();
      _truncatedMessageIds
        ..clear()
        ..addAll(
          _messages.where((message) => message.isTruncated).map((m) => m.id),
        );
      for (final message in _messages) {
        final savedSources = message.sources;
        if (savedSources.isNotEmpty) {
          _sourcesByMessageId[message.id] = savedSources;
          _activityByMessageId[message.id] = ['Pesquisou na web'];
        }
      }
      _messageKeys.clear();
      _historyWindow.reset();
      _followStream = true;
      _nearBottomCache = true;
    });
    _scrollToBottom(force: true);
  }

  void _scrollToBottom({bool force = false, bool followStream = false}) {
    // O stream pode emitir dezenas de tokens por segundo. Coalescemos os
    // callbacks e limitamos animações automáticas para evitar trepidação.
    if (_scrollCallbackScheduled) {
      _pendingForceScroll = _pendingForceScroll || force;
      return;
    }
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
      final effectiveForce = force || _pendingForceScroll;
      _pendingForceScroll = false;
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (ChatScrollPolicy.shouldFollow(
        forced: effectiveForce,
        userFollowing: _followStream && (followStream || _nearBottomCache),
      )) {
        if (effectiveForce && !(MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
          _scrollController.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          );
        } else {
          // Não empilhar dezenas de animações concorrentes por segundo.
          _scrollController.jumpTo(position.maxScrollExtent);
        }
      }
    });
  }

  Map<String, dynamic>? _readAttachmentMetadata(Message message) {
    final encoded = message.attachmentMetadataJson.trim();
    if (encoded.isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (error, stack) {
      logSwallowed(error, stack);
    }
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

  List<GeneratedImageData> _messageImageAttachments(Message message) {
    if (!message.isUser) return const [];
    final attachments = _readAttachmentMetadata(message)?['attachments'];
    if (attachments is! List) return const [];
    return attachments
        .whereType<Map>()
        .map((raw) {
          final item = Map<String, dynamic>.from(raw);
          if (item['kind']?.toString() != AttachmentKind.image.name)
            return null;
          final path = (item['libraryPath'] ?? item['sourcePath'] ?? '')
              .toString();
          if (path.isEmpty) return null;
          return GeneratedImageData(
            mime: (item['mimeType'] ?? 'image/jpeg').toString(),
            filePath: path,
          );
        })
        .whereType<GeneratedImageData>()
        .toList(growable: false);
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
        'libraryPath': a.libraryPath,
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
      final sourcePath = (data['sourcePath'] ?? '').toString();
      final libraryPath = (data['libraryPath'] ?? '').toString();
      final path = sourcePath.isNotEmpty && File(sourcePath).existsSync()
          ? sourcePath
          : libraryPath;
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
          )..libraryPath = libraryPath.isEmpty ? null : libraryPath,
        );
        continue;
      }

      if (path.isNotEmpty && await File(path).exists()) {
        final attachment = await _attachmentService.processFile(path);
        attachment.libraryPath = libraryPath.isEmpty ? null : libraryPath;
        restored.add(attachment);
        continue;
      }
      throw StateError(
        'O anexo "$name" não está disponível neste dispositivo. Anexe-o novamente para regenerar.',
      );
    }
    return restored;
  }

  String get _streamStatusLabel =>
      _voiceResponsePending ? 'Gamma ainda está respondendo' : _chatStatusLabel;

  String get _chatStatusLabel {
    if (_streamPhase.startsWith('artifact_generating:')) {
      final completed = _streamPhase.substring('artifact_generating:'.length);
      return 'Gerando arquivos · $completed concluídos';
    }
    switch (_streamPhase) {
      case 'searching':
        return _streamSearchQuery.isEmpty
            ? 'Buscando na web…'
            : 'Buscando: $_streamSearchQuery…';
      case 'project_analyzing':
        return _generationElapsed.inSeconds < 3
            ? 'Lendo arquivos do projeto… · $_elapsedLabel'
            : _generationElapsed.inSeconds < 8
            ? 'Mapeando dependências… · $_elapsedLabel'
            : 'Resumindo arquivos e pontos de entrada… · $_elapsedLabel';
      case 'generating_image':
        return _looksLikeImageEditRequest(
              _precedingUserPrompt(_messages.length),
            )
            ? 'Editando imagem…'
            : 'Criando imagem…';
      case 'image_analyzing':
        return 'Analisando imagem…';
      case 'video_queued':
        return 'Na fila · $_elapsedLabel';
      case 'video_generating':
        return 'Gerando vídeo · $_elapsedLabel';
      case 'video_downloading':
        return 'Salvando vídeo · $_elapsedLabel';
      case 'video_analyzing':
        return 'Analisando quadros do vídeo…';
      case 'video_editing':
        return 'Criando versão editada…';
      case 'video_improving':
        return 'Aprimorando vídeo…';
      case 'artifact_preparing':
        return 'Organizando arquivos solicitados…';
      case 'artifact_generating':
        return 'Gerando o conteúdo dos arquivos… · $_elapsedLabel';
      case 'artifact_validating':
        return 'Validando o pacote para download…';
      case 'thinking':
        return _generationElapsed.inSeconds < 3
            ? 'Analisando seu pedido…'
            : _generationElapsed.inSeconds < 8
            ? 'Preparando uma resposta…'
            : 'Ainda estou trabalhando na resposta… · $_elapsedLabel';
      case 'typing':
        return 'Escrevendo a resposta…';
      default:
        return 'Gama está respondendo…';
    }
  }

  void _recordActivity(String phase, {String? query}) {
    if (_messages.isEmpty || !_messages.last.isAssistant) return;
    final messageId = _messages.last.id;
    final label = switch (phase) {
      'searching' =>
        query == null || query.isEmpty
            ? 'Pesquisou na web'
            : 'Pesquisou: $query',
      'project_analyzing' => 'Leu arquivos do projeto',
      'generating_image' || 'image_analyzing' => 'Trabalhou com uma imagem',
      'video_queued' ||
      'video_generating' ||
      'video_downloading' => 'Gerou um vídeo',
      'video_analyzing' => 'Analisou o vídeo',
      'video_editing' => 'Editou o vídeo',
      'video_improving' => 'Aprimorou o vídeo',
      'artifact_preparing' => 'Preparou a entrega dos arquivos',
      'artifact_generating' => 'Gerou arquivos',
      'artifact_validating' => 'Validou o pacote gerado',
      _ => null,
    };
    if (label == null) return;
    final steps = _activityByMessageId.putIfAbsent(messageId, () => <String>[]);
    if (query != null && steps.isNotEmpty && steps.last == 'Pesquisou na web') {
      steps[steps.length - 1] = label;
      return;
    }
    if (steps.isEmpty || steps.last != label) steps.add(label);
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
        backgroundColor: context.gama.surfaceElevated,
        title: Text(
          'Editar mensagem',
          style: TextStyle(color: context.gama.textPrimary),
        ),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: editController,
            autofocus: true,
            minLines: 3,
            maxLines: 12,
            style: TextStyle(color: context.gama.textPrimary),
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

    // Ramificação segura: preserva a conversa original e todos os turnos
    // posteriores. O novo ramo recebe cópias das mensagens até a edição;
    // ids novos garantem sincronização independente entre dispositivos.
    final original = _service.conversationById(widget.conversationId);
    final branch = await _service.createDetachedConversation(
      title: 'Ramo · ${original?.title ?? 'Conversa'}',
      mode: original?.mode,
    );
    await _service.copyMessagesToBranch(
      sourceMessages: _messages.take(index).toList(),
      targetConversationId: branch.id,
    );
    if (!mounted) return;
    if (restored.isNotEmpty) {
      _snack('Ramo criado. Reanexe os arquivos do pedido editado antes de enviar.');
    }
    // Anexos não são transportados automaticamente para outro chat:
    // o texto editado fica como rascunho, sem simular envio de anexos.
    await Navigator.of(context).push(
      GamaPageRoute<void>(
        builder: (_) => ChatScreen(
          conversationId: branch.id,
          persistentSidebar: false,
          oficinaKind: widget.oficinaKind,
          initialPrompt: edited.trim(),
        ),
      ),
    );
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

  String _conversationMarkdown() {
    final title =
        _service.conversationById(widget.conversationId)?.title ??
        'Conversa Gama';
    final out = StringBuffer('# $title\n\n');
    for (final message in _messages) {
      final text = _cleanMessageText(message);
      if (text.isEmpty) continue;
      out.writeln(message.isUser ? '## Você' : '## Gama');
      out.writeln();
      out.writeln(text);
      out.writeln();
    }
    return out.toString().trim();
  }

  Future<void> _exportConversation() async {
    try {
      final text = _conversationMarkdown();
      final path = await DownloadService.instance.saveText(
        text,
        filename: 'conversa_gama_${DateTime.now().millisecondsSinceEpoch}.md',
      );
      await DownloadService.instance.openPath(path);
      _snack('Conversa exportada');
    } catch (error, stack) {
      logSwallowed(error, stack);
      _snack('Não foi possível exportar a conversa.');
    }
  }

  Future<void> _shareConversation(BuildContext shareContext) async {
    final text = _conversationMarkdown();
    if (text.isEmpty) return;
    try {
      final object = shareContext.findRenderObject();
      final box = object is RenderBox ? object : null;
      await SharePlus.instance.share(
        ShareParams(
          title: 'Conversa da Gama',
          text: text,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error, stack) {
      logSwallowed(error, stack);
      _snack('Não foi possível compartilhar a conversa.');
    }
  }

  Future<void> _copyMessage(Message message) async {
    await Clipboard.setData(ClipboardData(text: _cleanMessageText(message)));
    unawaited(HapticFeedback.lightImpact());
    _snack('Mensagem copiada');
  }

  Future<void> _speakMessage(Message message) async {
    if (!await PluginSettingsService.instance.isEnabled('tts')) {
      _snack('Voz (TTS) está desativada em Plugins.');
      return;
    }
    final text = _cleanMessageText(message);
    if (text.isEmpty || _isLoading) return;
    final request = ++_manualSpeechEpoch;
    if (TtsService.instance.isBusy) {
      await TtsService.instance.stop();
    }
    if (!mounted || request != _manualSpeechEpoch) return;
    _speechReveal.reset();
    _voiceReplyDisplayedText.value = '';
    setState(() {
      _voiceReplyDisplayMessageId = message.id;
      _isSpeaking = true;
    });
    try {
      await TtsService.instance.speakFull(
        text,
        onChunkPlaybackProgress: (chunk, fraction) {
          if (!mounted || request != _manualSpeechEpoch) return;
          _showSpeechProgress(chunk, fraction);
        },
      );
    } catch (error) {
      _snack('Não consegui reproduzir a mensagem: $error');
    } finally {
      if (mounted && request == _manualSpeechEpoch) {
        _voiceReplyDisplayMessageId = null;
        _voiceReplyDisplayedText.value = '';
        _speechReveal.reset();
        setState(() => _isSpeaking = false);
      }
    }
  }

  Future<void> _retryUserMessage(Message message, int index) async {
    if (_isLoading || !_canReusePrompt(message)) return;
    final assistantIndex = index + 1;
    if (assistantIndex == _messages.length - 1 &&
        _messages[assistantIndex].isAssistant) {
      if (_failedAssistantMessageId == _messages[assistantIndex].id) {
        await _retryLastFailedRequest();
      } else {
        await _regenerateResponse(assistantIndex);
      }
      return;
    }
    await _editAndResend(message, index);
  }

  void _showMessageContextMenu(Message message, int index) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copiar'),
              onTap: () {
                Navigator.pop(sheetContext);
                _copyMessage(message);
              },
            ),
            if (!message.isUser) ...[
              ListTile(
                leading: const Icon(Icons.volume_up_rounded),
                title: const Text('Ouvir resposta'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_speakMessage(message));
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_rounded),
                title: const Text('Compartilhar'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_shareMessage(message, context));
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Baixar'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_downloadMessage(message));
                },
              ),
              if (!_isLoading &&
                  index == _messages.length - 1 &&
                  index > 0 &&
                  _messages[index - 1].isUser &&
                  _canReusePrompt(_messages[index - 1]))
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('Regenerar resposta'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_regenerateResponse(index));
                  },
                ),
            ],
            if (message.isUser && !_isLoading && _canReusePrompt(message))
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Editar e reenviar'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _editAndResend(message, index);
                },
              ),
          ],
        ),
      ),
    );
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
        case 'retry':
          await _retryUserMessage(message, index);
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
          const PopupMenuItem(value: 'retry', child: Text('Tentar novamente')),
        if (isUser)
          const PopupMenuItem(value: 'download', child: Text('Baixar')),
        if (!isUser) ...[
          const PopupMenuItem(value: 'download', child: Text('Baixar')),
          const PopupMenuItem(value: 'share', child: Text('Compartilhar')),
        ],
      ],
    );

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(height: 38, child: moreButton),
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
            color: context.gama.textMuted,
            iconSize: 17,
          ),
          IconButton(
            tooltip: 'Ouvir mensagem',
            onPressed: () => unawaited(_speakMessage(message)),
            icon: const Icon(Icons.volume_up_rounded),
            color: context.gama.textMuted,
            iconSize: 18,
          ),
          if (canRegenerate)
            IconButton(
              tooltip: 'Regenerar resposta',
              onPressed: () => _regenerateResponse(index),
              icon: const Icon(Icons.refresh_rounded),
              color: context.gama.textMuted,
              iconSize: 18,
            ),
          IconButton(
            tooltip: 'Boa resposta',
            onPressed: () => _setMessageFeedback(message, 1),
            icon: Icon(
              Icons.thumb_up_alt_outlined,
              color: _feedbackByMessageId[message.id] == 1
                  ? context.gama.accent
                  : context.gama.textMuted,
            ),
            iconSize: 17,
          ),
          IconButton(
            tooltip: 'Resposta ruim',
            onPressed: () => _setMessageFeedback(message, -1),
            icon: Icon(
              Icons.thumb_down_alt_outlined,
              color: _feedbackByMessageId[message.id] == -1
                  ? context.gama.accent
                  : context.gama.textMuted,
            ),
            iconSize: 17,
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
      if (text.isNotEmpty) {
        path = await DownloadService.instance.saveText(text);
      }
      if (path != null) await DownloadService.instance.openPath(path);
      _snack(
        savedImages > 0
            ? 'Salvo ($savedImages imagem(ns))'
            : path != null
            ? 'Mensagem salva no dispositivo'
            : 'Não há conteúdo para salvar',
      );
    } catch (error, stack) {
      logSwallowed(error, stack);
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
    String filename, {
    String? expectedSha256,
    int? expectedSize,
  }) async {
    late final String savedPath;
    try {
      savedPath = await DownloadService.instance.downloadArtifact(
        '/artifacts/$artifactId/download',
        filename: filename,
        expectedSha256: expectedSha256,
        expectedSize: expectedSize,
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

  Future<void> _cacheVideoArtifact(Map<String, dynamic> artifact) async {
    final id = artifact['artifact_id']?.toString() ?? '';
    final filename = artifact['filename']?.toString() ?? 'gama_video.mp4';
    if (id.isEmpty) return;
    try {
      final path = await DownloadService.instance.downloadArtifact(
        '/artifacts/$id/download',
        filename: filename,
      );
      await LibraryScreen.addEntry(
        name: filename,
        kind: 'video',
        bytes: await File(path).length(),
        sourcePath: path,
        conversationId: widget.conversationId,
      );
      if (mounted) setState(() => _videoPathsByArtifactId[id] = path);
    } catch (error) {
      _snack('Não consegui preparar o vídeo: $error');
    }
  }

  void _showGeneratedFilePreview(Map<String, dynamic> file) {
    final title = file['name']?.toString() ?? 'Prévia do arquivo';
    final content = file['preview']?.toString() ?? 'Prévia indisponível.';
    if (defaultTargetPlatform == TargetPlatform.windows) {
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Fechar prévia',
        barrierColor: Colors.black54,
        pageBuilder: (context, _, __) => Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: context.gama.surface,
            child: SizedBox(
              width: MediaQuery.of(context).size.width * 0.55,
              height: double.infinity,
              child: _CodePreviewContent(title: title, content: content),
            ),
          ),
        ),
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: context.gama.surface,
        builder: (_) => SizedBox(
          height: MediaQuery.of(context).size.height * 0.82,
          child: _CodePreviewContent(title: title, content: content),
        ),
      );
    }
  }

  Future<void> _showAttachMenu() async {
    if (_isLoading || _waitingForAttachment) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.gama.surfaceElevated,
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
                    color: context.gama.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(
                  'Anexar',
                  style: TextStyle(
                    color: context.gama.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: Icon(
                    Icons.photo_camera_outlined,
                    color: context.gama.accent,
                  ),
                  title: Text(
                    'Câmera',
                    style: TextStyle(color: context.gama.textPrimary),
                  ),
                  subtitle: Text(
                    'Tirar foto',
                    style: TextStyle(
                      color: context.gama.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFromCamera();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.photo_library_outlined,
                    color: context.gama.accent,
                  ),
                  title: Text(
                    'Galeria',
                    style: TextStyle(color: context.gama.textPrimary),
                  ),
                  subtitle: Text(
                    'Escolher imagem',
                    style: TextStyle(
                      color: context.gama.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFromGallery();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.folder_open_rounded,
                    color: context.gama.accent,
                  ),
                  title: Text(
                    'Arquivos',
                    style: TextStyle(color: context.gama.textPrimary),
                  ),
                  subtitle: Text(
                    'PDF, ZIP, código, documentos…',
                    style: TextStyle(
                      color: context.gama.textMuted,
                      fontSize: 12,
                    ),
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

  Future<void> _pickFiles({bool zipOnly = false}) async {
    try {
      final result = await FilePicker.pickFiles(
        type: zipOnly ? FileType.custom : FileType.any,
        allowedExtensions: zipOnly ? const ['zip'] : null,
      );
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
      processed.libraryPath = await LibraryScreen.addEntry(
        name: processed.name,
        kind: processed.kind.name,
        bytes: processed.bytes,
        sourcePath: path,
        conversationId: widget.conversationId,
      );
      setState(() {
        _attachments.add(processed);
      });
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
    if (widget.oficinaKind != null) return false;
    final t = text.trim();
    final lower = t.toLowerCase();

    if (lower == '/limpar') {
      await _clearCurrentConversation();
      return true;
    }
    if (lower == '/modo programar' || lower == '/modo conversar') {
      final mode = lower.endsWith('programar')
          ? GamaMode.programar
          : GamaMode.conversar;
      setState(() => _mode = mode);
      await SettingsService.instance.setMode(mode);
      _snack(
        'Modo alterado para ${mode == GamaMode.programar ? 'Trabalhar' : 'Conversar'}',
      );
      return true;
    }

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
              backgroundColor: context.gama.surfaceCard,
              title: Text(
                'Memória',
                style: TextStyle(color: context.gama.textPrimary),
              ),
              content: SingleChildScrollView(
                child: Text(
                  body,
                  style: TextStyle(color: context.gama.textSecondary),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'Fechar',
                    style: TextStyle(color: context.gama.accent),
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


  /// O primeiro vocábulo troca o indicador de síntese pela mensagem real.
  /// Depois disso apenas o ValueNotifier da mensagem é reconstruído.
  void _showSpeechProgress(String chunk, double fraction) {
    if (!mounted) return;
    final hadText = _voiceReplyDisplayedText.value.isNotEmpty;
    final next = _speechReveal.advance(chunk, fraction);
    if (_voiceReplyDisplayedText.value != next) {
      _voiceReplyDisplayedText.value = next;
    }
    if (!hadText && next.isNotEmpty) setState(() {});
    if (next.isNotEmpty && _followStream && _voiceResponsePending) {
      _scrollToBottom(followStream: true);
    }
  }

  Future<void> _maybeSpeak(
    String text, {
    bool revealWhileSpeaking = false,
  }) async {
    final ttsEnabled = await PluginSettingsService.instance.isEnabled('tts');
    final want =
        ttsEnabled && (_speakNextReply || SettingsService.instance.ttsAuto);
    _speakNextReply = false;
    if (!want) {
      if (revealWhileSpeaking && mounted) {
        _voiceReplyDisplayMessageId = null;
        _voiceReplyDisplayedText.value = '';
        setState(() {});
      }
      return;
    }

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
      _speechReveal.reset();
      await TtsService.instance.speakFull(
        t,
        onChunkPlaybackProgress: (chunk, fraction) {
          if (!mounted) return;
          _showSpeechProgress(chunk, fraction);
        },
      );
    } finally {
      if (revealWhileSpeaking && mounted) {
        _voiceReplyDisplayMessageId = null;
        _voiceReplyDisplayedText.value = '';
      }
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
        conversationId: widget.conversationId,
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
    } catch (error, stack) {
      logSwallowed(error, stack);
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
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
    }
    _scrollToBottom();
  }

  Future<void> _retryLastFailedRequest() async {
    if (_isLoading || !_failedRequestRetryable ||
        _failedAssistantMessageId == null) return;
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

    // Continuidade visual: a API precisa receber os bytes da imagem de
    // referência na mensagem atual; o histórico substitui esses bytes por um
    // marcador para evitar reenviar base64 antigo.
    final draftText = _controller.text.trim();
    final isImageEdit = _looksLikeImageEditRequest(draftText);
    final alreadyHasImage = _attachments.any((a) => a.isNativeImage);
    if (isImageEdit && !alreadyHasImage) {
      final previousImagePath = _latestGeneratedImagePath();
      if (previousImagePath != null) {
        try {
          final attachment = await _attachmentService.processFile(
            previousImagePath,
          );
          if (!mounted) return;
          if (!attachment.isNativeImage) {
            _snack('Não consegui preparar a imagem anterior para edição.');
            return;
          }
          setState(() => _attachments.add(attachment));
        } catch (error, stack) {
          logSwallowed(error, stack);
          _snack('Não consegui carregar a imagem anterior para edição.');
          return;
        }
      } else if (widget.oficinaKind == OficinaKind.imagem) {
        _snack(
          'Não encontrei a imagem anterior. Anexe-a novamente para editar.',
        );
        return;
      }
    }

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
    var rawText = _controller.text.trim();
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
      _manualSpeechEpoch++;
      await TtsService.instance.stop();
      _voiceReplyDisplayMessageId = null;
      _voiceReplyDisplayedText.value = '';
      _speechReveal.reset();
      if (mounted) setState(() => _isSpeaking = false);
    }

    if (_micArmed || _isListening) {
      _micArmed = false;
      _speechSessionId++;
      _cancelSpeechRestart();
      _flushSpeechPartial();
      try {
        await _speech.stop();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
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

    final voiceRequested =
        (_speakNextReply || SettingsService.instance.ttsAuto) &&
        (pluginFlags['tts'] ?? true) && widget.oficinaKind == null;

    unawaited(HapticFeedback.lightImpact());
    _followStream = true;
    _streamSearchQuery = '';
    _streamRawText = StringBuffer();
    _streamDisplayFilter.reset();
    _pendingGeneratedImages.clear();
    _assistantPersistence = null;
    _streamRevealTimer?.cancel();
    _streamRevealTimer = null;
    _streamRevealLastFrame = null;
    _streamRevealBudget = 0;
    _streamRevealQueue.clear();
    _finishingStreamReveal = false;
    _streamRevealFinishStarted = null;
    _streamDisplayedBuffer = StringBuffer();
    _streamPreviewTruncated = false;
    _speechReveal.reset();
    _voiceReplyDisplayedText.value = '';
    _streamingText.value = '';

    final isRegeneration =
        _regeneratingAssistantMessage != null &&
        _regeneratingUserMessage != null;
    final pending = List<ProcessedAttachment>.from(_attachments);
    _retryRawText = rawText;
    _retryAttachments = List<ProcessedAttachment>.from(pending);
    if (_failedAssistantMessageId != null && !isRegeneration) {
      final failedId = _failedAssistantMessageId;
      final orphaned = _messages
          .where((m) => m.id == failedId && m.isAssistant)
          .toList();
      _messages.removeWhere((m) => m.id == failedId && m.isAssistant);
      if (orphaned.isNotEmpty) {
        await _service.deleteMessages(orphaned);
        _truncatedMessageIds.remove(failedId);
        _sourcesByMessageId.remove(failedId);
      }
    }
    _failedAssistantMessageId = null;
    _chatErrorMessage = null;
    _failedRequestRetryable = true;
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
        _newMessageAnimationId = userMessage.id;
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
    _startGenerationClock();
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
    assistantMessage.isTruncated = false;
    assistantMessage.sources = const <Map<String, dynamic>>[];
    _truncatedMessageIds.remove(assistantMessage.id);
    _sourcesByMessageId.remove(assistantMessage.id);
    _activityByMessageId.remove(assistantMessage.id);

    setState(() {
      if (!isRegeneration) {
        _messages.add(assistantMessage);
        _newMessageAnimationId = assistantMessage.id;
      }
      _voiceResponsePending = voiceRequested;
      _voiceResponseBuffer = '';
      _voiceReplyDisplayMessageId = voiceRequested ? assistantMessage.id : null;
      _voiceReplyDisplayedText.value = '';
    });
    try {
      await ConversationSyncService.instance.trackPendingGeneration(
        conversationId: widget.conversationId,
        assistantMessageId: assistantMessage.id,
      );
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
      final oficina = widget.oficinaKind;
      final resolvedChatMode = oficina != null
          ? oficina.chatMode
          : (_mode == GamaMode.conversar ? 'conversar' : 'programar');
      final resolvedModel = oficina == OficinaKind.programar
          ? AppConstants.modelOficinaProgramar
          : SettingsService.modelForMode(_mode);
      final stream = _ollama.chatStream(
        messages: apiMessages,
        model: resolvedModel,
        images: imagePayload.isEmpty ? null : imagePayload,
        voiceMode: willSpeak && oficina == null,
        chatMode: resolvedChatMode,
        imageAspectRatio: oficina == OficinaKind.imagem ? _imageAspectRatio : null,
        imageStyle: oficina == OficinaKind.imagem ? _imageStyle : null,
        videoDuration: oficina == OficinaKind.video ? _videoDuration : null,
        videoResolution: oficina == OficinaKind.video ? _videoResolution : null,
        videoAspectRatio: oficina == OficinaKind.video ? _videoAspectRatio : null,
        videoGenerateAudio: oficina == OficinaKind.video ? _videoGenerateAudio : null,
        conversationId: widget.conversationId,
        assistantMessageId: assistantMessage.id,
      );

      final generationEpoch = _generation.start();
      // TTS explícito e TTS automático usam a mesma sincronização incremental
      // durante a geração, sem esperar toda a resposta ficar pronta.
      if (voiceRequested && oficina == null && willSpeak) {
        try {
          _liveSpeech = await TtsService.instance.startStreamingSpeech(
            onChunkPlaybackStart: (chunk) {
              if (!mounted || !_generation.isCurrent(generationEpoch)) return;
              if (!_isSpeaking) setState(() => _isSpeaking = true);
            },
            onChunkPlaybackProgress: (chunk, fraction) {
              if (!mounted || !_generation.isCurrent(generationEpoch)) return;
              _showSpeechProgress(chunk, fraction);
            },
          );
          _ttsEarlyStarted = true;
        } catch (error, stack) {
          logSwallowed(error, stack);
          _liveSpeech = null;
        }
      }
      _streamSubscription = stream.listen(
        (event) {
          if (!_generation.isCurrent(generationEpoch)) return;
          if (event.truncated &&
              _messages.isNotEmpty &&
              _messages.last.isAssistant) {
            final truncatedMessage = _messages.last;
            truncatedMessage.isTruncated = true;
            _truncatedMessageIds.add(truncatedMessage.id);
            if (truncatedMessage.isInBox) {
              unawaited(
                _service.updateMessageContent(
                  truncatedMessage,
                  truncatedMessage.content,
                ),
              );
            }
            if (mounted) setState(() {});
          }
          if (!mounted) {
            final token = event.token;
            if (token != null) {
              if (_voiceResponsePending) {
                _voiceResponseBuffer += token;
                _liveSpeech?.append(token);
              } else {
                _streamRawText.write(token);
              }
            }
            return;
          }

          if (event.phase != null) {
            if (_streamPhase != event.phase) {
              setState(() => _streamPhase = event.phase!);
            }
            _recordActivity(event.phase!);
          }
          if (event.webSearchQuery != null &&
              event.webSearchQuery!.trim().isNotEmpty) {
            _streamSearchQuery = event.webSearchQuery!.trim();
            _streamPhase = 'searching';
            _recordActivity('searching', query: _streamSearchQuery);
            if (mounted) setState(() {});
          }
          if (event.memorySaved != null &&
              event.memorySaved!.trim().isNotEmpty) {
            _snack('Memória atualizada');
          }
          if (event.sources != null &&
              _messages.isNotEmpty &&
              _messages.last.isAssistant) {
            _recordActivity('searching', query: _streamSearchQuery);
            final sourceMessage = _messages.last;
            final sources = List<Map<String, dynamic>>.from(event.sources!);
            sourceMessage.sources = sources;
            _sourcesByMessageId[sourceMessage.id] = sources;
            if (sourceMessage.isInBox) {
              unawaited(
                _service.updateMessageContent(
                  sourceMessage,
                  sourceMessage.content,
                ),
              );
            }
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
            final incoming = Map<String, dynamic>.from(event.artifact!);
            final artifactId = incoming['artifact_id']?.toString();
            if (artifactId == null || artifactId.isEmpty ||
                !artifacts.any((a) => a['artifact_id'] == artifactId)) {
              artifacts.add(incoming);
              _messages.last.artifacts = artifacts;
              // Salva imediatamente se esta mensagem já estiver no Hive.
              // Respostas novas são salvas completas em onDone/onError.
              if (_messages.last.isInBox) {
                unawaited(_service.updateMessageContent(
                  _messages.last, _messages.last.content,
                ));
              }
              setState(() {});
            }
          }

          // Imagem gerada pelo backend (GPT Image 2.5 Sunburst)
          if (event.imageBase64 != null && event.imageBase64!.isNotEmpty) {
            final assistant = _messages.where((m) => m.isAssistant).toList();
            if (assistant.isNotEmpty) {
              final imageStore = _storeGeneratedImage(
                data: event.imageBase64!,
                mime: event.imageMime ?? 'image/png',
                messageId: assistant.last.id,
              );
              _pendingGeneratedImages.add(imageStore);
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
            _liveSpeech?.append(token);
          } else if (_messages.isNotEmpty && _messages.last.isAssistant) {
            _queueStreamText(token);
          }
          if (isFirstToken && mounted) setState(() {});
        },
        onDone: () async {
          if (!_generation.isCurrent(generationEpoch)) return;
          _streamSubscription = null;
          final isVoiceReply = _voiceResponsePending;
          // Evita corrida: a geração pode fechar enquanto a imagem ainda
          // está sendo escrita no disco/Hive. Aguarde antes de consolidar.
          if (_pendingGeneratedImages.isNotEmpty) {
            await Future.wait(List<Future<void>>.from(_pendingGeneratedImages));
            _pendingGeneratedImages.clear();
          }
          if (!_generation.isCurrent(generationEpoch)) return;
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
            // A imagem pode ser salva na biblioteca enquanto o texto da
            // resposta ainda está chegando. Preserve o bloco anexado pelo
            // _storeGeneratedImage em vez de sobrescrevê-lo ao fechar o stream.
            final generatedImageBlocks =
                RegExp(
                      r'\[gama_image_file\][\s\S]*?\[/gama_image_file\]|'
                      r'\[gama_image\][\s\S]*?\[/gama_image\]',
                    )
                    .allMatches(_messages.last.content)
                    .map((match) => match.group(0)!);
            _messages.last.content = [
              if (!isVoiceReply && completedText.isNotEmpty) completedText,
              ...generatedImageBlocks,
            ].join('\n\n');
            _finishStreamReveal(isVoiceReply ? '' : completedText,
                animate: !isVoiceReply);
          }
          final latestAssistant =
              _messages.isNotEmpty && _messages.last.isAssistant
              ? _messages.last
              : null;
          final hasArtifact = latestAssistant != null &&
              (_artifactsByMessageId[latestAssistant.id]?.isNotEmpty ?? false);
          final hasResponse = isVoiceReply
              ? (_voiceResponseBuffer.trim().isNotEmpty ||
                  (latestAssistant?.content.trim().isNotEmpty ?? false) ||
                  hasArtifact)
              : (_streamingText.value.trim().isNotEmpty ||
                  (latestAssistant?.content.trim().isNotEmpty ?? false) ||
                  hasArtifact);
          if (!hasResponse) {
            final speech = _liveSpeech;
            _liveSpeech = null;
            if (speech != null) await speech.cancel();
            _stopGenerationClock();
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
            await ConversationSyncService.instance.clearPendingGeneration(
              assistantMessage.id,
            );
            if (!_generation.isCurrent(generationEpoch)) return;
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
          _stopGenerationClock();

          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            _ttsEarlyStarted = false;
            final responseText = isVoiceReply
                ? _voiceResponseBuffer
                : extractGamaImages(_messages.last.content).$1;
            final assistantToSave = _messages.last;
            if (isVoiceReply) {
              // Preserve imagens criadas pela ferramenta mesmo quando a
              // resposta textual é revelada pelo TTS. O áudio fala apenas
              // responseText; o histórico mantém os blocos de mídia.
              final imageBlocks = RegExp(
                r'\[gama_image_file\][\s\S]*?\[/gama_image_file\]|'
                r'\[gama_image\][\s\S]*?\[/gama_image\]',
              ).allMatches(assistantToSave.content)
                  .map((match) => match.group(0)!)
                  .toList();
              assistantToSave.content = [
                responseText,
                ...imageBlocks,
              ].where((part) => part.trim().isNotEmpty).join('\n\n');
              _voiceReplyDisplayMessageId = assistantToSave.id;
              // A fala pode ter começado antes de o stream terminar.
              // Não apague as frases que já foram reproduzidas.
              if (_liveSpeech == null) _voiceReplyDisplayedText.value = '';
            }
            try {
              final pendingWrite = _assistantPersistence;
              if (pendingWrite != null) await pendingWrite;
              if (!_generation.isCurrent(generationEpoch)) return;
              if (isRegeneration || assistantToSave.isInBox) {
                await _service.updateMessageContent(
                  assistantToSave,
                  assistantToSave.content,
                );
              } else {
                await _service.addMessage(assistantToSave);
              }
              await ConversationSyncService.instance.clearPendingGeneration(
                assistantToSave.id,
              );
              // A resposta já está no Hive antes de iniciar qualquer TTS.
              if (!_generation.isCurrent(generationEpoch)) return;
              if (mounted) {
                if (isVoiceReply && _liveSpeech != null) {
                  final speech = _liveSpeech!;
                  try {
                    await speech.finish();
                  } finally {
                    if (identical(_liveSpeech, speech)) _liveSpeech = null;
                    if (_generation.isCurrent(generationEpoch) &&
                        _voiceReplyDisplayMessageId == assistantToSave.id) {
                      _speakNextReply = false;
                      _voiceReplyDisplayMessageId = null;
                      _voiceReplyDisplayedText.value = '';
                      if (mounted) setState(() => _isSpeaking = false);
                    }
                  }
                } else if (isVoiceReply) {
                  await _maybeSpeak(responseText, revealWhileSpeaking: true);
                } else {
                  await _maybeSpeak(responseText);
                }
              }
              if (!_generation.isCurrent(generationEpoch)) return;
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
              if (!_generation.isCurrent(generationEpoch)) return;
              // Se o áudio falhar, ainda mostramos a resposta completa para
              // não perder a mensagem que o servidor já gerou.
              if (isVoiceReply && mounted) {
                setState(() {
                  if (_messages.isNotEmpty && _messages.last.isAssistant) {
                    _messages.last.content = responseText;
                  }
                });
              }
              if (!assistantToSave.isInBox) {
                await _service.addMessage(assistantToSave);
              } else {
                await _service.updateMessageContent(
                  assistantToSave,
                  assistantToSave.content,
                );
              }
              if (!_generation.isCurrent(generationEpoch)) return;
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
              if (mounted && e is! ChatApiException) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Voz: $e'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } finally {
              if (_generation.isCurrent(generationEpoch)) {
                _voiceResponsePending = false;
                _voiceResponseBuffer = '';
                if (mounted && _voiceConversationMode) {
                  unawaited(_resumeVoiceConversation());
                }
              }
            }
          }
        },
        onError: (e) async {
          if (!_generation.isCurrent(generationEpoch)) return;
          final speech = _liveSpeech;
          _liveSpeech = null;
          if (speech != null) await speech.cancel();
          _stopGenerationClock();
          _streamRevealTimer?.cancel();
          _streamRevealTimer = null;
          _streamRevealQueue.clear();
          _finishingStreamReveal = false;
          final friendly = e is ChatApiException
              ? e.message
              : 'A resposta foi interrompida. Verifique a conexão e tente novamente.';
          final failed = _messages.isNotEmpty && _messages.last.isAssistant
              ? _messages.last
              : null;
          final partial =
              _voiceResponsePending && _voiceResponseBuffer.isNotEmpty
              ? _voiceResponseBuffer
              : _streamRawText.toString();
          if (failed != null && partial.trim().isNotEmpty) {
            failed.content = partial;
            try {
              final pendingWrite = _assistantPersistence;
              if (pendingWrite != null) await pendingWrite;
              if (!_generation.isCurrent(generationEpoch)) return;
              if (failed.isInBox) {
                await _service.updateMessageContent(failed, partial);
              } else {
                await _service.addMessage(failed);
              }
            } catch (persistError) {
              debugPrint(
                'Não foi possível persistir resposta parcial: $persistError',
              );
            }
          }
          if (!_generation.isCurrent(generationEpoch)) return;
          if (mounted) {
            setState(() {
              _failedAssistantMessageId = failed?.id;
              _chatErrorMessage = friendly;
              _failedRequestRetryable = e is! ChatApiException || e.retryable;
              _isLoading = false;
              _streamPhase = '';
              _voiceResponsePending = false;
              _voiceResponseBuffer = '';
              _speakNextReply = false;
              _isSpeaking = false;
            });
          }
          _regeneratingAssistantMessage = null;
          _regeneratingUserMessage = null;
        },
        cancelOnError: true,
      );
    } catch (e) {
      _stopGenerationClock();
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
        _failedRequestRetryable = e is! ChatApiException || e.retryable;
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
    final speech = _liveSpeech;
    _liveSpeech = null;
    if (speech != null) await speech.cancel();
    // Invalida os eventos de rede antes de aguardar o cancelamento remoto.
    _generation.invalidate();
    _stopGenerationClock();
    unawaited(HapticFeedback.lightImpact());
    final activeAssistant = _messages.isNotEmpty && _messages.last.isAssistant
        ? _messages.last
        : null;
    if (activeAssistant != null) {
      await _ollama.cancelChatGeneration(activeAssistant.id);
      await ConversationSyncService.instance.clearPendingGeneration(
        activeAssistant.id,
      );
    }
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    _finishStreamReveal(_streamRawText.toString());
    try {
      await TtsService.instance.stop();
    } catch (error, stack) {
      logSwallowed(error, stack, context: 'parar áudio');
    }
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
    _voiceReplyDisplayMessageId = null;
    _speechReveal.reset();
    _voiceReplyDisplayedText.value = '';
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
    final removed = List<Message>.from(_messages);
    if (removed.isEmpty) return;
    _clearMessagesTimer?.cancel();
    setState(() => _messages.clear());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Conversa limpa'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Desfazer',
          onPressed: () {
            _clearMessagesTimer?.cancel();
            if (mounted) {
              setState(() {
                _messages = [...removed, ..._messages]
                  ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
              });
            }
          },
        ),
      ),
    );
    _clearMessagesTimer = Timer(const Duration(seconds: 5), () {
      _clearMessagesTimer = null;
      // ignore: unawaited_futures
      _service.deleteMessages(removed);
    });
  }

  String _attachmentPrompt(String action) {
    final kind = _attachments.isEmpty
        ? AttachmentKind.other
        : _attachments.first.kind;
    final subject = switch (kind) {
      AttachmentKind.image => 'imagem',
      AttachmentKind.video => 'vídeo',
      AttachmentKind.audio => 'áudio',
      AttachmentKind.zip => 'projeto compactado',
      AttachmentKind.pdf => 'PDF',
      _ => 'arquivo',
    };
    return switch (action) {
      'Resuma' => 'Resuma o conteúdo do $subject que enviei.',
      'Analise' => 'Analise o $subject que enviei e destaque o que importa.',
      _ => 'Extraia os pontos principais e os próximos passos do $subject.',
    };
  }

  @override
  void dispose() {
    _manualSpeechEpoch++;
    if (_isSpeaking || TtsService.instance.isBusy) {
      unawaited(TtsService.instance.stop());
    }
    final speech = _liveSpeech;
    _liveSpeech = null;
    if (speech != null) unawaited(speech.cancel());
    SettingsService.instance.removeListener(_onModeSettingsChanged);
    _generation.invalidate();
    _generationClock.dispose();
    _cancelSpeechRestart();
    _micArmed = false;
    try {
      _speech.stop();
    } catch (error, stack) {
      logSwallowed(error, stack);
    }
    final activeAssistant = _messages.isNotEmpty && _messages.last.isAssistant
        ? _messages.last
        : null;
    if (_isLoading && activeAssistant != null) {
      final partial = _voiceResponsePending && _voiceResponseBuffer.isNotEmpty
          ? _voiceResponseBuffer
          : _streamRawText.toString();
      if (partial.trim().isNotEmpty) {
        activeAssistant.content = partial;
        _assistantPersistence = activeAssistant.isInBox
            ? _service.updateMessageContent(
                activeAssistant,
                partial,
                sync: false,
              )
            : _service.addMessage(activeAssistant, sync: false);
        unawaited(_assistantPersistence!);
      }
    }
    _streamRevealTimer?.cancel();
    _streamRevealLastFrame = null;
    _streamRevealBudget = 0;
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
    _voiceReplyDisplayedText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isWideDesktop = widget.persistentSidebar;
    return Material(
      color: Colors.transparent,
      child: DropTarget(
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
                color: context.gama.accentSoft,
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Text(
                  'Solte os arquivos para anexá-los',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.gama.accentBright,
                    fontSize: 12,
                  ),
                ),
              ),
            // App bar
            Container(
              decoration: BoxDecoration(
                color: context.gama.surface,
                border: Border(
                  bottom: BorderSide(color: context.gama.divider, width: 1),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
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
                        if (widget.oficinaKind != null)
                          IconButton(
                            tooltip: 'Voltar à Oficina',
                            icon: const Icon(Icons.arrow_back_rounded),
                            onPressed: () {
                              if (Navigator.of(context).canPop()) {
                                Navigator.of(context).pop();
                              } else {
                                Navigator.of(context).push(
                                  GamaPageRoute<void>(
                                    builder: (_) => const OficinaScreen(),
                                  ),
                                );
                              }
                            },
                          )
                        else if (!isWideDesktop)
                          Builder(
                            builder: (drawerContext) => IconButton(
                              tooltip: 'Abrir conversas',
                              style: IconButton.styleFrom(
                                backgroundColor: context.gama.surfaceCard,
                                foregroundColor: context.gama.textPrimary,
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
                                context.gama.surfaceHover,
                                context.gama.surfaceCard,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: context.gama.border),
                          ),
                          child: widget.oficinaKind == null
                              ? Image.asset(
                                  'assets/images/image3.png',
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => Icon(
                                    Icons.auto_awesome_rounded,
                                    color: context.gama.accent,
                                    size: 22,
                                  ),
                                )
                              : Icon(
                                  widget.oficinaKind!.icon,
                                  color: widget.oficinaKind!.color(
                                    context.gama,
                                  ),
                                  size: 21,
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
                                widget.oficinaKind?.label ?? 'Gama 2.0',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.gama.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (widget.oficinaKind == null)
                          PopupMenuButton<GamaMode>(
                            enabled: !_isLoading,
                            tooltip: 'Selecionar modo de IA',
                            onSelected: (value) async {
                              if (_mode == value) return;
                              setState(() => _mode = value);
                              await SettingsService.instance.setMode(value);
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: GamaMode.conversar,
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.chat_bubble_outline_rounded),
                                  title: Text('Conversar'),
                                  subtitle: Text('GPT-5.4 Mini'),
                                ),
                              ),
                              const PopupMenuItem(
                                value: GamaMode.programar,
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.code_rounded),
                                  title: Text('Trabalhar'),
                                  subtitle: Text('GLM 5.3 Flash'),
                                ),
                              ),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 12,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _mode == GamaMode.conversar
                                        ? 'Conversar'
                                        : 'Trabalhar',
                                    style: TextStyle(
                                      color: context.gama.textSecondary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Icon(Icons.expand_more_rounded,
                                      size: 16,
                                      color: context.gama.textSecondary),
                                ],
                              ),
                            ),
                          )
                        else if (widget.oficinaKind == OficinaKind.programar)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 7,
                            ),
                            child: Text('GLM 5.3 Flash',
                              style: TextStyle(
                                color: context.gama.textSecondary,
                                fontSize: 12,
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
                                await _openVoiceMode();
                                break;
                              case 'stop':
                                _stopGeneration();
                                break;
                              case 'settings':
                                Navigator.push(
                                  context,
                                  GamaPageRoute(
                                    builder: (_) => const SettingsScreen(),
                                  ),
                                );
                                break;
                              case 'clear':
                                _clearCurrentConversation();
                                break;
                              case 'export':
                                await _exportConversation();
                                break;
                              case 'share_chat':
                                await _shareConversation(context);
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
                            if (widget.oficinaKind == null)
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
                              value: 'export',
                              child: ListTile(
                                dense: true,
                                leading: Icon(Icons.download_outlined),
                                title: Text('Exportar conversa'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'share_chat',
                              child: ListTile(
                                dense: true,
                                leading: Icon(Icons.share_outlined),
                                title: Text('Compartilhar conversa'),
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
                    child: AnimatedSwitcher(
                      duration: MediaQuery.of(context).disableAnimations
                          ? Duration.zero
                          : GamaMotion.standard,
                      switchInCurve: GamaMotion.curve,
                      switchOutCurve: Curves.easeInCubic,
                      child: _messages.isEmpty
                          ? EmptyState(
                              key: const ValueKey('chat-empty'),
                              oficinaKind: widget.oficinaKind,
                              attachmentKinds: _attachments
                                  .map((attachment) => attachment.kind)
                                  .toList(growable: false),
                              draft: _controller,
                              onSuggestion: (action, text) {
                                if (widget.oficinaKind != null) {
                                  _controller.text = text;
                                  if (widget.oficinaKind ==
                                          OficinaKind.imagem &&
                                      _attachments.isEmpty &&
                                      (text.contains('imagem anexada') ||
                                          text.startsWith(
                                            'Analise esta imagem',
                                          ))) {
                                    _showAttachMenu();
                                    return;
                                  }
                                  _composerFocusNode.requestFocus();
                                  return;
                                }
                                if (action ==
                                    EmptySuggestionAction.reviewProject) {
                                  _controller.text = 'Revise meu projeto e destaque problemas e melhorias.';
                                  _showAttachMenu();
                                  return;
                                }
                                if (action ==
                                    EmptySuggestionAction.explainError) {
                                  _controller.text = 'Explique este erro:\n';
                                  _composerFocusNode.requestFocus();
                                  return;
                                }
                                _controller.text = switch (action) {
                                  EmptySuggestionAction.write =>
                                    'Ajude-me a escrever: ',
                                  EmptySuggestionAction.explain =>
                                    'Explique este assunto de forma simples: ',
                                  EmptySuggestionAction.brainstorm =>
                                    'Ajude-me a pensar em ideias para: ',
                                  EmptySuggestionAction.summarizeAttachment =>
                                    _attachmentPrompt('Resuma'),
                                  EmptySuggestionAction.describeAttachment => 'Descreva a imagem anexada com detalhes visuais claros, incluindo textos legíveis, se houver.',
                                  EmptySuggestionAction.analyzeAttachment =>
                                    _attachmentPrompt('Analise'),
                                  EmptySuggestionAction.extractTasks =>
                                    _attachmentPrompt(
                                      'Extraia os pontos principais e as tarefas de',
                                    ),
                                  EmptySuggestionAction.editAttachment =>
                                    'Sugira alterações para a imagem anexada.',
                                  _ => 'Ajude-me com: ',
                                };
                                _composerFocusNode.requestFocus();
                              },
                            )
                          : NotificationListener<ScrollNotification>(
                              key: const ValueKey('chat-messages'),
                              onNotification: _handleListScrollNotification,
                              child: ListView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  22,
                                  16,
                                  26,
                                ),
                                cacheExtent: 320,
                                itemCount: _historyWindow.listLength(_messages.length),
                                itemBuilder: (context, listIndex) {
                                  if (listIndex == 0 &&
                                      _historyWindow.hasOlder(_messages.length)) {
                                    return Center(
                                      child: Padding(
                                        padding: const EdgeInsets.only(bottom: 14),
                                        child: TextButton.icon(
                                          onPressed: _loadEarlierMessages,
                                          icon: const Icon(Icons.history_rounded, size: 18),
                                          label: Text(
                                            'Carregar mensagens anteriores (${_historyWindow.remaining(_messages.length)})',
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  // Mantém o índice REAL usado por editar,
                                  // regenerar, anexos e histórico de fontes.
                                  final index = _historyWindow.messageIndex(
                                    listIndex, _messages.length,
                                  );
                                  final msg = _messages[index];
                                  final isUser = msg.isUser;
                                  final isLastAssistant =
                                      !isUser && index == _messages.length - 1;

                                  return TweenAnimationBuilder<double>(
                                    key: ValueKey('message-enter-${msg.id}'),
                                    tween: Tween(
                                      begin: msg.id == _newMessageAnimationId
                                          ? 0.0
                                          : 1.0,
                                      end: 1.0,
                                    ),
                                    duration:
                                        MediaQuery.of(context).disableAnimations
                                        ? Duration.zero
                                        : msg.id == _newMessageAnimationId
                                        ? const Duration(milliseconds: 180)
                                        : Duration.zero,
                                    curve: Curves.easeOutCubic,
                                    onEnd: () {
                                      if (mounted &&
                                          _newMessageAnimationId == msg.id) {
                                        setState(
                                          () => _newMessageAnimationId = null,
                                        );
                                      }
                                    },
                                    child: Semantics(
                                      container: true,
                                      explicitChildNodes: true,
                                      label: isUser
                                          ? 'Você disse'
                                          : 'Gama respondeu',
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onLongPress: () =>
                                            _showMessageContextMenu(msg, index),
                                        child: RepaintBoundary(
                                          key: _messageKeyFor(msg.id),
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
                                                      : CrossAxisAlignment
                                                            .start,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Container(
                                                      constraints:
                                                          BoxConstraints(
                                                            maxWidth: isUser
                                                                ? 680
                                                                : 760,
                                                          ),
                                                      margin: EdgeInsets.only(
                                                        bottom: isUser ? 8 : 4,
                                                      ),
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical: 12,
                                                          ),
                                                      decoration: isUser
                                                          ? BoxDecoration(
                                                              gradient: LinearGradient(
                                                                begin: Alignment
                                                                    .topLeft,
                                                                end: Alignment
                                                                    .bottomRight,
                                                                colors: [
                                                                  context
                                                                      .gama
                                                                      .bubbleUserSoft,
                                                                  context
                                                                      .gama
                                                                      .bubbleUser,
                                                                ],
                                                              ),
                                                              borderRadius: const BorderRadius.only(
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
                                                                color: context
                                                                    .gama
                                                                    .accent
                                                                    .withValues(
                                                                      alpha:
                                                                          0.20,
                                                                    ),
                                                              ),
                                                            )
                                                          : BoxDecoration(
                                                              color: context
                                                                  .gama
                                                                  .surfaceCard,
                                                              borderRadius: const BorderRadius.only(
                                                                topLeft:
                                                                    Radius.circular(
                                                                      7,
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
                                                                      22,
                                                                    ),
                                                              ),
                                                              border: Border.all(
                                                                color: context
                                                                    .gama
                                                                    .border
                                                                    .withValues(
                                                                      alpha:
                                                                          0.45,
                                                                    ),
                                                              ),
                                                            ),
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
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
                                                                content:
                                                                    msg.content,
                                                                isUser: false,
                                                                onTapLink:
                                                                    _openLink,
                                                              ),
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            ChatStatusIndicator(
                                                              label:
                                                                  _chatErrorMessage!,
                                                              isError: true,
                                                              onRetry:
                                                                  _isLoading || !_failedRequestRetryable
                                                                  ? null
                                                                  : _retryLastFailedRequest,
                                                              onContinue:
                                                                  !_isLoading &&
                                                                      msg.content
                                                                          .trim()
                                                                          .isNotEmpty &&
                                                                      _truncatedMessageIds
                                                                          .contains(
                                                                            msg.id,
                                                                          )
                                                                  ? _continueResponse
                                                                  : null,
                                                            ),
                                                          ] else if (msg
                                                                  .content
                                                                  .isEmpty &&
                                                              !isUser &&
                                                              _isLoading &&
                                                              !_firstTokenReceived)
                                                            widget.oficinaKind ==
                                                                        OficinaKind
                                                                            .imagem &&
                                                                    _streamPhase ==
                                                                        'generating_image'
                                                                ? _ImageGenerationPlaceholder(
                                                                    aspectRatio:
                                                                        _imageAspectRatio,
                                                                  )
                                                                : widget.oficinaKind ==
                                                                      OficinaKind
                                                                          .video
                                                                ? Column(
                                                                    crossAxisAlignment:
                                                                        CrossAxisAlignment
                                                                            .start,
                                                                    children: [
                                                                      _timedStreamStatus(),
                                                                      _VideoGenerationProgress(
                                                                        phase:
                                                                            _streamPhase,
                                                                      ),
                                                                      TextButton.icon(
                                                                        onPressed:
                                                                            _stopGeneration,
                                                                        icon: const Icon(
                                                                          Icons
                                                                              .close_rounded,
                                                                          size:
                                                                              16,
                                                                        ),
                                                                        label:
                                                                            const Text(
                                                                              'Cancelar',
                                                                            ),
                                                                      ),
                                                                    ],
                                                                  )
                                                                : _timedStreamStatus()
                                                          else if (!isUser &&
                                                              isLastAssistant &&
                                                              _voiceResponsePending &&
                                                              _voiceReplyDisplayedText.value.isEmpty)
                                                            _timedStreamStatus()
                                                          else if (!isUser &&
                                                              isLastAssistant &&
                                                              (_isLoading || _finishingStreamReveal) &&
                                                              !_voiceResponsePending &&
                                                              _firstTokenReceived)
                                                            ValueListenableBuilder<
                                                              String
                                                            >(
                                                              valueListenable:
                                                                  _streamingText,
                                                              builder: (context, content, _) =>
                                                                  widget.oficinaKind ==
                                                                          OficinaKind
                                                                              .imagem &&
                                                                      _streamPhase == 'generating_image'
                                                                  ? _ImageGenerationPlaceholder(
                                                                      aspectRatio:
                                                                          _imageAspectRatio,
                                                                    )
                                                                  : Column(
                                                                      crossAxisAlignment:
                                                                          CrossAxisAlignment
                                                                              .start,
                                                                      mainAxisSize:
                                                                          MainAxisSize
                                                                              .min,
                                                                      children: [
                                                                        MessageContentView(
                                                                          streaming:
                                                                              true,
                                                                          content: _citationMarkdown(
                                                                            msg.id,
                                                                            content,
                                                                          ),
                                                                          isUser:
                                                                              false,
                                                                          onTapLink:
                                                                              _openLink,
                                                                        ),
                                                                        if (!_finishingStreamReveal)
                                                                          const _StreamingCursor(),
                                                                      ],
                                                                    ),
                                                            )
                                                          else if (!isUser &&
                                                              msg.id == _voiceReplyDisplayMessageId &&
                                                              _voiceReplyDisplayedText.value.isEmpty)
                                                            const ChatStatusIndicator(label: 'Preparando áudio…')
                                                          else if (!isUser &&
                                                              msg.id ==
                                                                  _voiceReplyDisplayMessageId)
                                                            ValueListenableBuilder<
                                                              String
                                                            >(
                                                              valueListenable:
                                                                  _voiceReplyDisplayedText,
                                                              builder:
                                                                  (
                                                                    context,
                                                                    content,
                                                                    _,
                                                                  ) => MessageContentView(
                                                                    streaming: true,
                                                                    content:
                                                                        _citationMarkdown(
                                                                          msg.id,
                                                                          content,
                                                                        ),
                                                                    isUser:
                                                                        false,
                                                                    onTapLink:
                                                                        _openLink,
                                                                  ),
                                                            )
                                                          else
                                                            MemoizedMessageContentView(
                                                              referenceCode:
                                                                  !isUser &&
                                                                      widget.oficinaKind ==
                                                                          OficinaKind
                                                                              .programar
                                                                  ? widget
                                                                        .codeComparisonBase
                                                                  : null,
                                                              referenceLanguage:
                                                                  widget
                                                                      .codeComparisonLanguage,
                                                              content:
                                                                  _citationMarkdown(
                                                                    msg.id,
                                                                    msg.content,
                                                                  ),
                                                              isUser: isUser,
                                                              onTapLink:
                                                                  _openLink,
                                                              additionalImages:
                                                                  _messageImageAttachments(
                                                                    msg,
                                                                  ),
                                                            ),
                                                          if (!isUser &&
                                                              widget.oficinaKind ==
                                                                  OficinaKind
                                                                      .imagem &&
                                                              (msg.content
                                                                      .contains(
                                                                        '[gama_image_file]',
                                                                      ) ||
                                                                  msg.content
                                                                      .contains(
                                                                        '[gama_image]',
                                                                      ))) ...[
                                                            if (_beforeImagePath !=
                                                                    null &&
                                                                _imagePathFromContent(
                                                                      msg.content,
                                                                    ) !=
                                                                    null &&
                                                                _imagePathFromContent(
                                                                      msg.content,
                                                                    ) !=
                                                                    _beforeImagePath)
                                                              _BeforeAfterImageSlider(
                                                                beforePath:
                                                                    _beforeImagePath!,
                                                                afterPath:
                                                                    _imagePathFromContent(
                                                                      msg.content,
                                                                    )!,
                                                              ),
                                                            _ImageCreationActions(
                                                              onVary: () => _varyGeneratedImage(
                                                                _imagePathFromContent(
                                                                  msg.content,
                                                                ),
                                                                'Crie uma variação da imagem anterior com esta direção: ${_precedingUserPrompt(index)}',
                                                              ),
                                                              onEdit: () {
                                                                final path =
                                                                    _imagePathFromContent(
                                                                      msg.content,
                                                                    );
                                                                _beforeImagePath =
                                                                    path;
                                                                unawaited(
                                                                  _editGeneratedImage(
                                                                    path,
                                                                    'Edite a imagem anterior: ${_precedingUserPrompt(index)}',
                                                                  ),
                                                                );
                                                              },
                                                              onRegenerate: () =>
                                                                  _sendImageFollowup(
                                                                    _precedingUserPrompt(
                                                                      index,
                                                                    ),
                                                                  ),
                                                              onViewPrompt: () => showDialog<void>(
                                                                context:
                                                                    context,
                                                                builder: (ctx) => AlertDialog(
                                                                  title:
                                                                      const Text(
                                                                        'Prompt da imagem',
                                                                      ),
                                                                  content:
                                                                      SelectableText(
                                                                        _precedingUserPrompt(
                                                                          index,
                                                                        ),
                                                                      ),
                                                                  actions: [
                                                                    TextButton(
                                                                      onPressed: () =>
                                                                          Navigator.pop(
                                                                            ctx,
                                                                          ),
                                                                      child:
                                                                          const Text(
                                                                            'Fechar',
                                                                          ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                          if (!isUser &&
                                                              (msg.content
                                                                      .contains(
                                                                        'diff --git',
                                                                      ) ||
                                                                  RegExp(
                                                                    r'^@@ .* @@',
                                                                    multiLine:
                                                                        true,
                                                                  ).hasMatch(
                                                                    msg.content,
                                                                  )))
                                                            _UnifiedDiffCard(
                                                              content:
                                                                  msg.content,
                                                            ),
                                                          if (!isUser &&
                                                              (_artifactsByMessageId[msg
                                                                          .id]
                                                                      ?.isNotEmpty ??
                                                                  false)) ...[
                                                            const SizedBox(
                                                              height: 12,
                                                            ),
                                                            ArtifactStatusList(
                                                              artifacts:
                                                                  _artifactsByMessageId[msg
                                                                      .id]!,
                                                              videoPaths:
                                                                  _videoPathsByArtifactId,
                                                              onPlayVideo:
                                                                  _cacheVideoArtifact,
                                                              onPreview:
                                                                  _showGeneratedFilePreview,
                                                              onDownload: (artifact) {
                                                                final id =
                                                                    artifact['artifact_id']
                                                                        ?.toString() ??
                                                                    '';
                                                                final filename =
                                                                    artifact['filename']
                                                                        ?.toString() ??
                                                                    'gamma_arquivo.zip';
                                                                if (id
                                                                    .isNotEmpty) {
                                                                  _downloadGeneratedArtifact(
                                                                    id,
                                                                    filename,
                                                                    expectedSha256:
                                                                        artifact['sha256']
                                                                            ?.toString(),
                                                                    expectedSize: int.tryParse(
                                                                        artifact['size']
                                                                            ?.toString() ?? ''),
                                                                  );
                                                                }
                                                              },
                                                            ),
                                                          ],
                                                          if (!isUser &&
                                                              ((_activityByMessageId[msg
                                                                              .id]
                                                                          ?.isNotEmpty ??
                                                                      false) ||
                                                                  (_sourcesByMessageId[msg
                                                                              .id]
                                                                          ?.isNotEmpty ??
                                                                      false) ||
                                                                  (_isLoading &&
                                                                      isLastAssistant &&
                                                                      const <String>[
                                                                        'searching',
                                                                        'project_analyzing',
                                                                        'image_analyzing',
                                                                        'generating_image',
                                                                        'video_analyzing',
                                                                        'video_generating',
                                                                        'video_downloading',
                                                                      ].contains(
                                                                        _streamPhase,
                                                                      ))))
                                                            ValueListenableBuilder<Duration>(
                                                              valueListenable: _generationClock,
                                                              builder: (context, _, __) => _ActivityTimeline(
                                                                key: ValueKey('activity-${msg.id}'),
                                                                steps: _activityByMessageId[msg.id] ?? const [],
                                                                sources: _sourcesByMessageId[msg.id] ?? const [],
                                                                isRunning: _isLoading && isLastAssistant,
                                                                activeStep: _isLoading && isLastAssistant
                                                                    ? _chatStatusLabel
                                                                    : null,
                                                              ),
                                                            ),
                                                          if (!isUser &&
                                                              !_isLoading &&
                                                              _truncatedMessageIds
                                                                  .contains(
                                                                    msg.id,
                                                                  ))
                                                            Align(
                                                              alignment: Alignment
                                                                  .centerLeft,
                                                              child: TextButton.icon(
                                                                onPressed:
                                                                    _continueResponse,
                                                                icon: const Icon(
                                                                  Icons
                                                                      .more_horiz_rounded,
                                                                  size: 18,
                                                                ),
                                                                label:
                                                                    const Text(
                                                                      'Continuar',
                                                                    ),
                                                              ),
                                                            ),
                                                          if (!isUser &&
                                                              !_isLoading &&
                                                              msg
                                                                      .variants
                                                                      .length >
                                                                  1)
                                                            Padding(
                                                              padding:
                                                                  const EdgeInsets.only(
                                                                    top: 8,
                                                                  ),
                                                              child: Row(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  IconButton(
                                                                    tooltip: 'Versão anterior',
                                                                    constraints:
                                                                        const BoxConstraints.tightFor(
                                                                          width:
                                                                              48,
                                                                          height:
                                                                              48,
                                                                        ),
                                                                    padding:
                                                                        EdgeInsets
                                                                            .zero,
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
                                                                      color: context
                                                                          .gama
                                                                          .textMuted,
                                                                      fontSize:
                                                                          12,
                                                                    ),
                                                                  ),
                                                                  IconButton(
                                                                    tooltip: 'Próxima versão',
                                                                    constraints:
                                                                        const BoxConstraints.tightFor(
                                                                          width:
                                                                              48,
                                                                          height:
                                                                              48,
                                                                        ),
                                                                    padding:
                                                                        EdgeInsets
                                                                            .zero,
                                                                    onPressed:
                                                                        msg.selectedVariantIndex <
                                                                            msg.variants.length -
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
                                                    if (msg.content
                                                        .trim()
                                                        .isNotEmpty)
                                                      _messageActions(
                                                        msg,
                                                        index,
                                                        isLastAssistant,
                                                      ),
                                                    if (!isUser)
                                                      const SizedBox(
                                                        height: 12,
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    builder: (context, value, child) => Opacity(
                                      opacity: value,
                                      child: Transform.translate(
                                        offset: Offset(0, (1 - value) * 8),
                                        child: child,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                    ),
                  ),
                  if (_showScrollToBottom || (_isLoading && !_followStream))
                    Positioned(
                      right: 16,
                      bottom: 14,
                      child: AnimatedOpacity(
                        opacity: 1,
                        duration: MediaQuery.of(context).disableAnimations
                            ? Duration.zero
                            : const Duration(milliseconds: 150),
                        child: FloatingActionButton.small(
                          heroTag: 'gama_scroll_to_bottom',
                          tooltip: 'Ir para o fim da conversa',
                          backgroundColor: context.gama.surfaceElevated,
                          foregroundColor: context.gama.accentBright,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: context.gama.accentSoft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: context.gama.accent.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    const GamaSkeleton(width: 18, height: 18, radius: 9),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _processingLabel ?? 'Processando anexo…',
                        style: TextStyle(
                          color: context.gama.textPrimary,
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
                color: context.gama.surface,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _attachments.map((a) {
                    if (a.kind.name == 'image' && a.sourcePath != null) {
                      return Container(
                        width: 220,
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: context.gama.surfaceCard,
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(color: context.gama.border),
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
                                    color: context.gama.surfaceHover,
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
                                    fontSize: 12,
                                    color: context.gama.textPrimary,
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
                        color: context.gama.surfaceCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: context.gama.border),
                      ),
                      child: Chip(
                        avatar: CircleAvatar(
                          backgroundColor: context.gama.accentSoft,
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
                            color: context.gama.accent,
                          ),
                        ),
                        label: Text(
                          a.label,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.gama.textPrimary,
                          ),
                        ),
                        backgroundColor: Colors.transparent,
                        side: BorderSide.none,
                        deleteIcon: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: context.gama.textMuted,
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
              isLoading: _isLoading,
              isListening: _isListening,
              hasAttachments: _attachments.isNotEmpty,
              attachmentsReady: !_processingAttachment &&
                  !_waitingForAttachment && !_attachmentProcessingFailed,
              mode: _mode,
              onAttach: _showAttachMenu,
              onToggleListen: _toggleListen,
              onOpenVoice: widget.oficinaKind == null ? _openVoiceMode : null,
              onSend: _sendMessage,
              onSpeakSend: _sendMessageWithVoiceReply,
              onPasteImage: _pasteClipboardContent,
              showSlashMenu: _showSlashSuggestions,
              oficinaKind: widget.oficinaKind,
              placeholder: switch (widget.oficinaKind) {
                OficinaKind.imagem => 'Descreva a imagem que quer criar…',
                OficinaKind.video => 'Descreva o vídeo…',
                OficinaKind.programar =>
                  'Peça um app, anexe um ZIP ou cole um link do GitHub…',
                null => null,
              },
              onExitOficina: widget.oficinaKind == null
                  ? null
                  : () async {
                      await _service.updateConversationMode(
                        widget.conversationId,
                        null,
                      );
                      if (mounted)
                        Navigator.of(context)
                            .popUntil((route) => route.isFirst);
                    },
              imageAspectRatio: _imageAspectRatio,
              imageStyle: _imageStyle,
              videoDuration: _videoDuration,
              videoResolution: _videoResolution,
              videoAspectRatio: _videoAspectRatio,
              videoGenerateAudio: _videoGenerateAudio,
              onVideoDurationChanged: (v) => setState(() => _videoDuration = v),
              onVideoResolutionChanged: (v) => setState(() => _videoResolution = v),
              onVideoAspectRatioChanged: (v) => setState(() => _videoAspectRatio = v),
              onVideoGenerateAudioChanged: (v) => setState(() => _videoGenerateAudio = v),
              onImageAspectRatioChanged: (value) =>
                  setState(() => _imageAspectRatio = value),
              onImageStyleChanged: (value) =>
                  setState(() => _imageStyle = value),
              oficinaShortcuts: widget.oficinaKind == OficinaKind.programar
                  ? [
                      ActionChip(
                        avatar: const Icon(Icons.folder_zip_outlined, size: 16),
                        label: const Text('Anexar ZIP'),
                        onPressed: () => _pickFiles(zipOnly: true),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.link_rounded, size: 16),
                        label: const Text('Colar link do GitHub'),
                        onPressed: () {
                          _controller.text =
                              'Analise este repositório: https://github.com/';
                          _composerFocusNode.requestFocus();
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.bug_report_outlined, size: 16),
                        label: const Text('Colar erro'),
                        onPressed: () {
                          _controller.text = 'Explique este erro:\n';
                          _composerFocusNode.requestFocus();
                        },
                      ),
                    ]
                  : const [],
              onSlashCommandSelected: _selectSlashCommand,
              onStop: _stopGeneration,
              onModeChanged: (m) async {
                setState(() => _mode = m);
                await SettingsService.instance.setMode(m);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceFavicon extends StatelessWidget {
  final Uri? uri;

  const _SourceFavicon({required this.uri});

  @override
  Widget build(BuildContext context) {
    final host = uri?.host ?? '';
    final hasHttpScheme = uri?.scheme == 'http' || uri?.scheme == 'https';
    if (!hasHttpScheme || host.isEmpty || host == 'localhost') {
      return Icon(
        Icons.language_rounded,
        color: context.gama.textMuted,
        size: 18,
      );
    }
    final favicon = Uri(scheme: 'https', host: host, path: '/favicon.ico');
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        favicon.toString(),
        width: 20,
        height: 20,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(
          Icons.language_rounded,
          color: context.gama.textMuted,
          size: 18,
        ),
      ),
    );
  }
}

class _CodePreviewContent extends StatelessWidget {
  final String title;
  final String content;
  const _CodePreviewContent({required this.title, required this.content});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
          child: Row(
            children: [
              Icon(Icons.code_rounded, color: context.gama.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.gama.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Divider(color: context.gama.divider, height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: SelectableText(
              content,
              style: TextStyle(
                color: context.gama.textPrimary,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _VideoGenerationProgress extends StatelessWidget {
  final String phase;
  const _VideoGenerationProgress({required this.phase});

  @override
  Widget build(BuildContext context) {
    final current = phase == 'video_downloading'
        ? 2
        : phase == 'video_generating'
        ? 1
        : 0;
    const labels = ['Na fila', 'Gerando', 'Salvando'];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            Icon(
              i < current
                  ? Icons.check_circle
                  : i == current
                  ? Icons.circle
                  : Icons.circle_outlined,
              size: 12,
              color: i <= current
                  ? context.gama.accentCool
                  : context.gama.textHint,
            ),
            const SizedBox(width: 4),
            Text(
              labels[i],
              style: TextStyle(
                color: i == current
                    ? context.gama.textSecondary
                    : context.gama.textMuted,
                fontSize: 10,
              ),
            ),
            if (i < labels.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Container(
                  width: 14,
                  height: 1,
                  color: context.gama.border,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _UnifiedDiffCard extends StatelessWidget {
  final String content;
  const _UnifiedDiffCard({required this.content});

  @override
  Widget build(BuildContext context) {
    final lines = content
        .split('\n')
        .where(
          (line) =>
              line.startsWith('diff --git ') ||
              line.startsWith('@@ ') ||
              line.startsWith('+') ||
              line.startsWith('-') ||
              line.startsWith(' '),
        )
        .toList();
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: context.gama.surfaceCard,
        border: Border.all(color: context.gama.borderSoft),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        leading: Icon(Icons.difference_outlined, color: context.gama.accent),
        title: const Text('Visualização de alterações'),
        children: [
          Container(
            constraints: const BoxConstraints(maxHeight: 360),
            width: double.infinity,
            color: context.gama.surface,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final line = lines[index];
                final color = line.startsWith('+')
                    ? const Color(0x332E9B62)
                    : line.startsWith('-')
                    ? const Color(0x33D94A4A)
                    : Colors.transparent;
                return Container(
                  color: color,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  child: SelectableText(
                    line,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityTimeline extends StatelessWidget {
  final List<String> steps;
  final List<Map<String, dynamic>> sources;
  final bool isRunning;
  final String? activeStep;

  const _ActivityTimeline({
    super.key,
    required this.steps,
    required this.sources,
    required this.isRunning,
    this.activeStep,
  });

  @override
  Widget build(BuildContext context) {
    final title = isRunning ? 'Atividade em andamento' : 'Etapas da resposta';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: context.gama.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.gama.borderSoft),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          leading: Icon(
            isRunning ? Icons.pending_outlined : Icons.task_alt_outlined,
            size: 18,
            color: context.gama.accent,
          ),
          title: Text(
            title,
            style: TextStyle(
              color: context.gama.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          children: [
            if (isRunning && activeStep != null && activeStep!.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Icon(
                        Icons.bolt_rounded,
                        size: 15,
                        color: context.gama.accent,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          activeStep!,
                          style: TextStyle(
                            color: context.gama.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            for (final step in steps)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '•  $step',
                    style: TextStyle(
                      color: context.gama.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            for (var index = 0; index < sources.length; index++)
              Builder(
                builder: (context) {
                  final source = sources[index];
                  final title =
                      (source['title'] ?? source['url'] ?? 'Fonte ${index + 1}')
                          .toString();
                  final url = (source['url'] ?? source['link'] ?? '')
                      .toString();
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: url.isEmpty
                          ? null
                          : () => launchUrl(
                              Uri.parse(url),
                              mode: LaunchMode.externalApplication,
                            ),
                      icon: const Icon(Icons.open_in_new_rounded, size: 14),
                      label: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _ImageCreationActions extends StatelessWidget {
  final VoidCallback onVary;
  final VoidCallback onEdit;
  final VoidCallback onRegenerate;
  final VoidCallback onViewPrompt;

  const _ImageCreationActions({
    required this.onVary,
    required this.onEdit,
    required this.onRegenerate,
    required this.onViewPrompt,
  });

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    runSpacing: 2,
    children: [
      TextButton.icon(
        onPressed: onVary,
        icon: const Icon(Icons.auto_awesome, size: 16),
        label: const Text('Variar'),
      ),
      TextButton.icon(
        onPressed: onEdit,
        icon: const Icon(Icons.tune_rounded, size: 16),
        label: const Text('Editar'),
      ),
      TextButton.icon(
        onPressed: onRegenerate,
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: const Text('Regenerar'),
      ),
      TextButton.icon(
        onPressed: onViewPrompt,
        icon: const Icon(Icons.subject_rounded, size: 16),
        label: const Text('Ver prompt'),
      ),
    ],
  );
}

class _BeforeAfterImageSlider extends StatefulWidget {
  final String beforePath;
  final String afterPath;
  const _BeforeAfterImageSlider({
    required this.beforePath,
    required this.afterPath,
  });

  @override
  State<_BeforeAfterImageSlider> createState() =>
      _BeforeAfterImageSliderState();
}

class _BeforeAfterImageSliderState extends State<_BeforeAfterImageSlider> {
  double _position = 0.5;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Antes · Depois',
        style: TextStyle(
          color: context.gama.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: LayoutBuilder(
            builder: (context, bounds) => Stack(
              fit: StackFit.expand,
              children: [
                Image.file(File(widget.beforePath), fit: BoxFit.cover),
                ClipRect(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: _position,
                    child: SizedBox(
                      width: bounds.maxWidth,
                      height: bounds.maxHeight,
                      child: Image.file(
                        File(widget.afterPath),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: bounds.maxWidth * _position - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
      Slider(
        value: _position,
        onChanged: (value) => setState(() => _position = value),
      ),
    ],
  );
}

/// Indicador compacto: não ocupa uma tela inteira enquanto a imagem é gerada.
/// Evita também ShaderMask sobre áreas grandes (inconsistente em alguns GPUs).
class _ImageGenerationPlaceholder extends StatelessWidget {
  final String aspectRatio;

  const _ImageGenerationPlaceholder({required this.aspectRatio});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
        decoration: BoxDecoration(
          color: context.gama.surfaceElevated,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: context.gama.borderSoft),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded,
                    color: context.gama.accent, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Criando sua imagem…',
                    style: TextStyle(
                      color: context.gama.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  aspectRatio,
                  style: TextStyle(
                    color: context.gama.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: context.gama.borderSoft,
                valueColor: AlwaysStoppedAnimation<Color>(context.gama.accent),
              ),
            ),
          ],
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
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

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
      style: TextStyle(color: context.gama.accentBright, fontSize: 17),
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
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
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
                    color: context.gama.accent.withValues(alpha: 0.85),
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
