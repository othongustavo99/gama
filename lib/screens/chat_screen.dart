import 'dart:async';
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

import '../core/gama_colors.dart';
import '../models/message.dart';
import '../services/attachment_service.dart';
import '../services/conversation_service.dart';
import '../services/memory_service.dart';
import '../services/ollama_service.dart';
import 'library_screen.dart';
import 'settings_screen.dart';
import '../widgets/message_content.dart';
import '../widgets/chat_composer.dart';
import '../services/settings_service.dart';
import '../services/download_service.dart';
import '../utils/message_sanitize.dart';
import '../services/tts_service.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;

  const ChatScreen({super.key, required this.conversationId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
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
    _initSpeech();
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
      _isLoading = false;
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
    });
    _scrollToBottom(force: true);
  }

  void _scrollToBottom({bool force = false}) {
    // O stream pode emitir dezenas de tokens por segundo. Coalescemos os
    // callbacks e limitamos animações automáticas para evitar trepidação.
    if (_scrollCallbackScheduled) return;
    if (!force) {
      final now = DateTime.now();
      final last = _lastAutoScrollAt;
      if (last != null && now.difference(last) < const Duration(milliseconds: 120)) {
        return;
      }
      _lastAutoScrollAt = now;
    }
    _scrollCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCallbackScheduled = false;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (force || position.pixels >= position.maxScrollExtent - 120) {
        _scrollController.animateTo(
          position.maxScrollExtent,
          duration: Duration(milliseconds: force ? 180 : 90),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _canReusePrompt(Message message) {
    if (!message.isUser) return false;
    final content = message.content;
    // O histórico visível de anexos não contém o payload original da imagem nem
    // o texto integral indexado do projeto. Não oferecer reenvio que os perderia.
    return !content.contains('Anexos para análise:') &&
        !content.contains('[arquivo:') &&
        !content.contains('[project_id:') &&
        !content.contains('[gama_image]');
  }

  Future<void> _editAndResend(Message message, int index) async {
    if (_isLoading || !_canReusePrompt(message) || index < 0 || index >= _messages.length) {
      return;
    }
    final editController = TextEditingController(text: message.content);
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GamaColors.surfaceElevated,
        title: const Text('Editar mensagem', style: TextStyle(color: GamaColors.textPrimary)),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: editController,
            autofocus: true,
            minLines: 3,
            maxLines: 12,
            style: const TextStyle(color: GamaColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'Edite o pedido para a Gamma',
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

    final removed = List<Message>.from(_messages.skip(index));
    await _service.deleteMessages(removed, sync: false);
    if (!mounted) return;
    setState(() {
      for (final item in removed) {
        _artifactsByMessageId.remove(item.id);
      }
      _messages.removeRange(index, _messages.length);
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
      _snack('Não é possível regenerar esta resposta porque a mensagem anterior contém anexos.');
      return;
    }
    final removed = List<Message>.from(_messages.skip(assistantIndex - 1));
    await _service.deleteMessages(removed, sync: false);
    if (!mounted) return;
    setState(() {
      for (final item in removed) {
        _artifactsByMessageId.remove(item.id);
      }
      _messages.removeRange(assistantIndex - 1, _messages.length);
      _controller.text = prompt.content;
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
    _snack('Mensagem copiada');
  }

  Future<void> _downloadMessage(Message message) async {
    try {
      final imagePattern = RegExp(
        r'\[gama_image\]\s*mime:([^\n]+)\s*data:([A-Za-z0-9+/=\s]+)\s*\[/gama_image\]',
        multiLine: true,
      );
      var savedImages = 0;
      for (final match in imagePattern.allMatches(message.content)) {
        await DownloadService.instance.saveBase64Image(
          match.group(2)!,
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
    } catch (error) {
      _snack('Falha ao salvar: $error');
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
          title: 'Mensagem da Gamma',
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
                const Text(
                  'Anexar',
                  style: TextStyle(
                    color: GamaColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(
                    Icons.photo_camera_outlined,
                    color: GamaColors.accent,
                  ),
                  title: const Text(
                    'Câmera',
                    style: TextStyle(color: GamaColors.textPrimary),
                  ),
                  subtitle: const Text(
                    'Tirar foto',
                    style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFromCamera();
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.photo_library_outlined,
                    color: GamaColors.accent,
                  ),
                  title: const Text(
                    'Galeria',
                    style: TextStyle(color: GamaColors.textPrimary),
                  ),
                  subtitle: const Text(
                    'Escolher imagem',
                    style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickFromGallery();
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.folder_open_rounded,
                    color: GamaColors.accent,
                  ),
                  title: const Text(
                    'Arquivos',
                    style: TextStyle(color: GamaColors.textPrimary),
                  ),
                  subtitle: const Text(
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
              title: const Text(
                'Memória',
                style: TextStyle(color: GamaColors.textPrimary),
              ),
              content: SingleChildScrollView(
                child: Text(
                  body,
                  style: const TextStyle(color: GamaColors.textSecondary),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
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
    final want = _speakNextReply || SettingsService.instance.ttsAuto;
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

    final rawText = _controller.text.trim();
    if ((rawText.isEmpty && _attachments.isEmpty) || _isLoading) return;

    // Se a Gamma ainda estiver falando a resposta anterior, interrompe
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

    final voiceRequested = _speakNextReply;

    final pending = List<ProcessedAttachment>.from(_attachments);
    final apiText = AttachmentService.buildMessageBody(rawText, pending);
    final displayText = AttachmentService.buildDisplayMessage(rawText, pending);
    final imagePayload = AttachmentService.buildImagesPayload(pending);
    _attachments.clear();

    final userMessage = Message(
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
    if (!mounted) return;
    _controller.clear();
    _speechConfirmed = '';
    _speechPartial = '';
    _speechLastFinalText = '';
    _scrollToBottom(force: true);

    final conv = _service.currentConversation;
    if (conv != null && (conv.title == 'Nova conversa' || conv.title.isEmpty)) {
      final preview = rawText.isNotEmpty ? rawText : 'Arquivo(s) anexado(s)';
      final shortTitle = preview.length > 40
          ? '${preview.substring(0, 40)}...'
          : preview;
      await _service.renameConversation(widget.conversationId, shortTitle);
    }

    final assistantMessage = Message(
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
      final willSpeak = voiceRequested || SettingsService.instance.ttsAuto;
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
            final mime = event.imageMime ?? 'image/png';
            final block =
                '\n[gama_image]\nmime:$mime\ndata:${event.imageBase64}\n[/gama_image]\n';
            setState(() {
              if (_messages.isNotEmpty && _messages.last.isAssistant) {
                _messages.last.content = (_messages.last.content) + block;
              }
            });
          }

          final token = event.token;
          if (token == null) return;

          setState(() {
            _streamPhase = 'typing';
            if (_voiceResponsePending) {
              // Mantém a resposta fora da UI enquanto a Gamma ainda está
              // gerando. O conteúdo será revelado quando o áudio começar.
              _voiceResponseBuffer += token;
            } else if (_messages.isNotEmpty && _messages.last.isAssistant) {
              _messages.last.content += token;
            }
          });

          if (!_voiceResponsePending) {
            _scrollToBottom();
          }
        },
        onDone: () async {
          final isVoiceReply = _voiceResponsePending;
          _voiceResponseBuffer = _voiceResponseBuffer.replaceAll(
            RegExp(
              r'\[\[GAMA_FILES\]\][\s\S]*?\[\[/GAMA_FILES\]\]',
              caseSensitive: false,
            ),
            '',
          ).trim();
          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            _messages.last.content = _messages.last.content.replaceAll(
              RegExp(
                r'\[\[GAMA_FILES\]\][\s\S]*?\[\[/GAMA_FILES\]\]',
                caseSensitive: false,
              ),
              '',
            ).trim();
          }
          if (_messages.isNotEmpty && _messages.last.isAssistant) {
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
              await _service.addMessage(_messages.last);
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
              await _service.addMessage(_messages.last);
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
            }
          }
        },
        onError: (e) async {
          if (!mounted) return;
          final errorMessage = 'Desculpa, deu erro: $e';
          setState(() {
            if (_messages.isNotEmpty && _messages.last.isAssistant) {
              _messages.last.content = _messages.last.content.isEmpty
                  ? errorMessage
                  : '${_messages.last.content}\n\n[Erro: $e]';
            }
            _isLoading = false;
            _streamPhase = '';
                });
          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            await _service.addMessage(_messages.last);
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_messages.isNotEmpty) {
          _messages.last.content = 'Desculpa, deu erro: $e';
        }
        _isLoading = false;
      });
      if (_messages.isNotEmpty) {
        await _service.addMessage(_messages.last);
      }
    }
  }

  Future<void> _stopGeneration() async {
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    await TtsService.instance.stop();
    _isSpeaking = false;
    if (!mounted) return;
    final lastMessage = _messages.isNotEmpty ? _messages.last : null;
    if (lastMessage != null && lastMessage.isAssistant) {
      if (_voiceResponsePending && _voiceResponseBuffer.isNotEmpty) {
        lastMessage.content = _voiceResponseBuffer;
      }
      if (lastMessage.content.isNotEmpty) {
        await _service.addMessage(lastMessage);
      }
    }
    _voiceResponsePending = false;
    _voiceResponseBuffer = '';
    _speakNextReply = false;
    _isSpeaking = false;
    setState(() {
      if (lastMessage != null &&
          lastMessage.isAssistant &&
          lastMessage.content.isEmpty) {
        _messages.remove(lastMessage);
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
        title: const Text(
          'Limpar esta conversa?',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: const Text(
          'Isso apaga todas as mensagens desta conversa.',
          style: TextStyle(color: GamaColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: GamaColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Apagar',
              style: TextStyle(color: GamaColors.error),
            ),
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
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // App bar
        Container(
          decoration: BoxDecoration(
            color: GamaColors.surface,
            border: const Border(
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
                  height: 64,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        IconButton(
                          style: IconButton.styleFrom(
                            backgroundColor: GamaColors.surfaceCard,
                            foregroundColor: GamaColors.textPrimary,
                          ),
                          icon: const Icon(Icons.menu_rounded, size: 20),
                          onPressed: () => Scaffold.of(context).openDrawer(),
                        ),
                        const SizedBox(width: 5),
                        Container(
                          width: 36,
                          height: 36,
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [GamaColors.surfaceHover, GamaColors.surfaceCard],
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: GamaColors.border),
                          ),
                          child: Image.asset(
                            'assets/images/image3.png',
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.auto_awesome_rounded,
                              color: GamaColors.accent,
                              size: 22,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Gamma 2.0',
                                style: TextStyle(
                                  color: GamaColors.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.25,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'ASSISTENTE PESSOAL',
                                style: TextStyle(
                                  color: GamaColors.textMuted,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_isLoading || _isSpeaking)
                          IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: GamaColors.accentSoft,
                              foregroundColor: GamaColors.accentBright,
                            ),
                            icon: const Icon(Icons.stop_rounded, size: 19),
                            tooltip: 'Parar geração',
                            onPressed: _stopGeneration,
                          ),
                        IconButton(
                          icon: const Icon(Icons.settings_outlined, size: 20),
                          tooltip: 'Configurações',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const SettingsScreen(),
                              ),
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 20),
                          tooltip: 'Limpar conversa',
                          onPressed: _clearCurrentConversation,
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
              // Logo de fundo (marca d'água)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.055,
                    child: Center(
                      child: Image.asset(
                        'assets/images/image2.png',
                        width: 340,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: _messages.isEmpty
                    ? _EmptyState(
                        onSuggestion: (text) {
                          _controller.text = text;
                          _sendMessage();
                        },
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 22, 16, 26),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final isUser = msg.isUser;

                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: isUser
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                              onLongPress: () async {
                                final action =
                                    await showModalBottomSheet<String>(
                                      context: context,
                                      backgroundColor:
                                          GamaColors.surfaceElevated,
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(
                                          top: Radius.circular(16),
                                        ),
                                      ),
                                      builder: (ctx) => SafeArea(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (!_isLoading && isUser && _canReusePrompt(msg))
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.edit_note_rounded,
                                                  color: GamaColors.accent,
                                                ),
                                                title: const Text(
                                                  'Editar e reenviar',
                                                  style: TextStyle(color: GamaColors.textPrimary),
                                                ),
                                                subtitle: const Text(
                                                  'Substitui esta mensagem e as respostas seguintes',
                                                  style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
                                                ),
                                                onTap: () => Navigator.pop(ctx, 'edit_resend'),
                                              ),
                                            if (!_isLoading &&
                                                !isUser &&
                                                index == _messages.length - 1 &&
                                                index > 0 &&
                                                _messages[index - 1].isUser &&
                                                _canReusePrompt(_messages[index - 1]))
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.refresh_rounded,
                                                  color: GamaColors.accent,
                                                ),
                                                title: const Text(
                                                  'Regenerar resposta',
                                                  style: TextStyle(color: GamaColors.textPrimary),
                                                ),
                                                subtitle: const Text(
                                                  'Tenta outra resposta para a última mensagem',
                                                  style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
                                                ),
                                                onTap: () => Navigator.pop(ctx, 'regenerate'),
                                              ),
                                            ListTile(
                                              leading: const Icon(
                                                Icons.copy_rounded,
                                                color: GamaColors.accent,
                                              ),
                                              title: const Text(
                                                'Copiar texto',
                                                style: TextStyle(
                                                  color: GamaColors.textPrimary,
                                                ),
                                              ),
                                              onTap: () =>
                                                  Navigator.pop(ctx, 'copy'),
                                            ),
                                            ListTile(
                                              leading: const Icon(
                                                Icons.download_rounded,
                                                color: GamaColors.accent,
                                              ),
                                              title: const Text(
                                                'Baixar no dispositivo',
                                                style: TextStyle(
                                                  color: GamaColors.textPrimary,
                                                ),
                                              ),
                                              onTap: () => Navigator.pop(
                                                ctx,
                                                'download',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                if (!mounted || action == null) return;
                                if (action == 'copy') {
                                  await _copyMessage(msg);
                                } else if (action == 'download') {
                                  await _downloadMessage(msg);
                                } else if (action == 'edit_resend') {
                                  await _editAndResend(msg, index);
                                } else if (action == 'regenerate') {
                                  await _regenerateResponse(index);
                                }
                              },
                              child: Container(
                                constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(context).size.width *
                                      (isUser ? 0.86 : 0.94),
                                ),
                                margin: EdgeInsets.only(bottom: isUser ? 16 : 4),
                                padding: EdgeInsets.symmetric(
                                  horizontal: isUser ? 16 : 14,
                                  vertical: isUser ? 12 : 14,
                                ),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? null
                                      : GamaColors.bubbleAssistant,
                                  gradient: isUser
                                      ? const LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            GamaColors.bubbleUserSoft,
                                            GamaColors.bubbleUser,
                                          ],
                                        )
                                      : null,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(22),
                                    topRight: const Radius.circular(22),
                                    bottomLeft: Radius.circular(isUser ? 22 : 7),
                                    bottomRight: Radius.circular(isUser ? 7 : 22),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: isUser
                                          ? GamaColors.accent.withOpacity(0.10)
                                          : Colors.black.withOpacity(0.16),
                                      blurRadius: isUser ? 18 : 12,
                                      offset: const Offset(0, 5),
                                    ),
                                  ],
                                  border: isUser
                                      ? Border.all(
                                          color: GamaColors.accent.withOpacity(0.20),
                                        )
                                      : Border.all(
                                          color: GamaColors.borderSoft,
                                          width: 0.9,
                                        ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!isUser) ...[
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 22,
                                            height: 22,
                                            decoration: BoxDecoration(
                                              color: GamaColors.accentSoft,
                                              borderRadius: BorderRadius.circular(7),
                                            ),
                                            child: const Icon(
                                              Icons.auto_awesome_rounded,
                                              size: 13,
                                              color: GamaColors.accentBright,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          const Text(
                                            'GAMMA',
                                            style: TextStyle(
                                              color: GamaColors.textMuted,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 1.1,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                    ],
                                    if (msg.content.isEmpty && !isUser && _isLoading)
                                      const _TypingDots()
                                    else
                                      MessageContentView(
                                        content: msg.content,
                                        isUser: isUser,
                                        onTapLink: _openLink,
                                      ),
                                    if (!isUser &&
                                        (_artifactsByMessageId[msg.id]?.isNotEmpty ?? false)) ...[
                                      const SizedBox(height: 12),
                                      _ArtifactStatusList(
                                        artifacts: _artifactsByMessageId[msg.id]!,
                                        onDownload: (artifact) {
                                          final id = artifact['artifact_id']?.toString() ?? '';
                                          final filename = artifact['filename']?.toString() ?? 'gamma_arquivo.zip';
                                          if (id.isNotEmpty) {
                                            _downloadGeneratedArtifact(id, filename);
                                          }
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                                ),
                            if (!isUser && msg.content.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 2, top: 1),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Copiar',
                                      onPressed: () => _copyMessage(msg),
                                      icon: const Icon(Icons.copy_rounded),
                                      color: GamaColors.textMuted,
                                      hoverColor: GamaColors.accentSoft,
                                      iconSize: 17,
                                      padding: const EdgeInsets.all(7),
                                      constraints: const BoxConstraints.tightFor(
                                        width: 34,
                                        height: 34,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    const SizedBox(width: 5),
                                    IconButton(
                                      tooltip: 'Baixar no dispositivo',
                                      onPressed: () => _downloadMessage(msg),
                                      icon: const Icon(Icons.download_rounded),
                                      color: GamaColors.textMuted,
                                      hoverColor: GamaColors.accentSoft,
                                      iconSize: 18,
                                      padding: const EdgeInsets.all(7),
                                      constraints: const BoxConstraints.tightFor(
                                        width: 34,
                                        height: 34,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    const SizedBox(width: 5),
                                    Builder(
                                      builder: (shareContext) => IconButton(
                                        tooltip: 'Compartilhar',
                                        onPressed: () => _shareMessage(
                                          msg,
                                          shareContext,
                                        ),
                                        icon: const Icon(Icons.share_rounded),
                                        color: GamaColors.textMuted,
                                        hoverColor: GamaColors.accentSoft,
                                        iconSize: 17,
                                        padding: const EdgeInsets.all(7),
                                        constraints:
                                            const BoxConstraints.tightFor(
                                          width: 34,
                                          height: 34,
                                        ),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (!isUser) const SizedBox(height: 12),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),

        if (_isLoading || _isSpeaking)
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _isSpeaking
                    ? 'Gamma ainda está respondendo...'
                    : _streamPhase == 'searching'
                    ? 'Buscando na web…'
                    : _streamPhase == 'generating_image'
                    ? 'Criando imagem…'
                    : _streamPhase == 'image_analyzing'
                    ? 'Analisando imagem…'
                    : _streamPhase == 'project_analyzing'
                    ? 'Analisando projeto…'
                    : _streamPhase == 'video_queued'
                    ? 'Preparando vídeo…'
                    : _streamPhase == 'video_generating'
                    ? 'Gerando vídeo…'
                    : _streamPhase == 'video_downloading'
                    ? 'Salvando vídeo…'
                    : _streamPhase == 'video_analyzing'
                    ? 'Analisando quadros do vídeo…'
                    : _streamPhase == 'video_editing'
                    ? 'Criando versão editada…'
                    : _streamPhase == 'video_improving'
                    ? 'Aprimorando vídeo…'
                    : _streamPhase == 'thinking'
                    ? 'Pensando…'
                    : 'Gamma está respondendo…',
                style: TextStyle(
                  color: GamaColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
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
                const SizedBox(
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
                    style: const TextStyle(
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: GamaColors.textPrimary,
                      ),
                    ),
                    backgroundColor: Colors.transparent,
                    side: BorderSide.none,
                    deleteIcon: const Icon(
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
          isLoading: _isLoading || _waitingForAttachment,
          isListening: _isListening,
          mode: _mode,
          onAttach: _showAttachMenu,
          onToggleListen: _toggleListen,
          onSend: _sendMessage,
          onSpeakSend: () {
            _speakNextReply = true;
            _sendMessage();
          },
          onModeChanged: (m) async {
            setState(() => _mode = m);
            await SettingsService.instance.setMode(m);
          },
        ),
      ],
    );
  }
}

class _ArtifactStatusList extends StatelessWidget {
  final List<Map<String, dynamic>> artifacts;
  final ValueChanged<Map<String, dynamic>> onDownload;

  const _ArtifactStatusList({required this.artifacts, required this.onDownload});

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
      children: artifacts.map((artifact) {
        final filename = artifact['filename']?.toString() ?? 'arquivo gerado';
        final kind = artifact['kind']?.toString() ?? 'zip';
        final structural = artifact['validation'] is Map
            ? Map<String, dynamic>.from(artifact['validation'] as Map)
            : <String, dynamic>{};
        final source = artifact['source_validation'] is Map
            ? Map<String, dynamic>.from(artifact['source_validation'] as Map)
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
                    isZip ? Icons.folder_zip_outlined : isVideo ? Icons.movie_outlined : Icons.description_outlined,
                    color: GamaColors.accentBright,
                    size: 19,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      filename,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
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
                      zipOk ? Icons.check_circle_outline : Icons.error_outline,
                      size: 16,
                      color: zipOk ? GamaColors.accentBright : Colors.orangeAccent,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        zipOk
                            ? 'Integridade do ZIP: passou (estrutura/CRC)'
                            : 'Integridade do ZIP: falhou',
                        style: const TextStyle(color: GamaColors.textSecondary, fontSize: 12),
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
                      color: syntaxStatus == 'issues_found' ? Colors.orangeAccent : GamaColors.accentBright,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _validationLabel(source),
                        style: const TextStyle(color: GamaColors.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                if (source.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Arquivos verificados: $checked · não verificados: $unverified · problemas: $issues',
                    style: const TextStyle(color: GamaColors.textMuted, fontSize: 11),
                  ),
                  if (source['note'] is String)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        source['note'].toString(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: GamaColors.textMuted, fontSize: 10.5),
                      ),
                    ),
                ],
              ] else if (isVideo) ...[
                Text(
                  'Vídeo gerado${artifact['duration_seconds'] == null ? '' : ' · ${artifact['duration_seconds']} s'}${artifact['resolution'] == null ? '' : ' · ${artifact['resolution']}'} · $videoAudioLabel',
                  style: const TextStyle(color: GamaColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Confira o resultado antes de compartilhar ou substituir o original.',
                  style: TextStyle(color: GamaColors.textMuted, fontSize: 11),
                ),
                if (providerCost != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Custo informado pela OpenRouter: US\$${providerCost.toStringAsFixed(4)}',
                    style: const TextStyle(color: GamaColors.textMuted, fontSize: 11),
                  ),
                ],
              ] else ...[
                Text(
                  structural['ok'] == true
                      ? 'Arquivo gerado e validado estruturalmente.'
                      : 'O arquivo precisa de verificação adicional.',
                  style: const TextStyle(color: GamaColors.textSecondary, fontSize: 12),
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
      }).toList(growable: false),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ValueChanged<String> onSuggestion;

  const _EmptyState({required this.onSuggestion});

  static const _suggestions = [
    'Anexe ZIP/PDF/código e peça uma análise',
    'Vamos iniciar um Projeto',
    '/memoria listar',
  ];
  static const _suggestionTitles = [
    'Analisar um projeto',
    'Planejar uma ideia',
    'Consultar minha memória',
  ];
  static const _suggestionDescriptions = [
    'Revise arquivos, documentação ou código.',
    'Organize os próximos passos com a Gamma.',
    'Veja o que a assistente lembra sobre você.',
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
                  gradient: const LinearGradient(
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
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color.fromARGB(126, 25, 31, 41),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: GamaColors.borderSoft),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: GamaColors.success, size: 7),
                    SizedBox(width: 7),
                    Text(
                      'SEU ESPAÇO DE TRABALHO',
                      style: TextStyle(
                        color: GamaColors.textSecondary,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              const Text(
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
              const Text(
                'Converse, programe ou explore uma ideia.\nA Gamma ajuda você a dar o próximo passo.',
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
                                    style: const TextStyle(
                                      color: GamaColors.textPrimary,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _suggestionDescriptions[index],
                                    style: const TextStyle(
                                      color: GamaColors.textMuted,
                                      fontSize: 11.5,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
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
