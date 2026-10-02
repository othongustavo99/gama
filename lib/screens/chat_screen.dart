import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/gama_colors.dart';
import '../models/message.dart';
import '../services/attachment_service.dart';
import '../services/conversation_service.dart';
import '../services/memory_service.dart';
import '../services/ollama_service.dart';
import 'library_screen.dart';
import 'settings_screen.dart';

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
  List<WebSource> _pendingSources = [];
  StreamSubscription<ChatStreamEvent>? _streamSubscription;

  /// Arquivos anexados (ainda não enviados)
  final List<ProcessedAttachment> _attachments = [];
  final _attachmentService = AttachmentService();
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _isListening = false;
  bool _micArmed = false;
  String? _textBeforeMic;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    try {
      _speechReady = await _speech.initialize(
        onStatus: (s) {
          if (!mounted) return;
          if (_micArmed && (s == 'done' || s == 'notListening')) {
            Future.microtask(() => _resumeListenIfArmed());
          }
        },
        onError: (e) {
          debugPrint('speech error: $e');
        },
        debugLogging: kDebugMode,
      );
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('speech init: $e');
      _speechReady = false;
    }
  }

  Future<void> _resumeListenIfArmed() async {
    if (!_micArmed || !mounted || !_speechReady) return;
    try {
      await _startListenSession();
    } catch (e) {
      debugPrint('resume listen: $e');
    }
  }

  Future<void> _startListenSession() async {
    try {
      await _speech.listen(
        localeId: 'pt_BR',
        partialResults: true,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(minutes: 15),
        pauseFor: const Duration(seconds: 45),
        onResult: _onSpeechResult,
      );
    } catch (_) {
      await _speech.listen(
        partialResults: true,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(minutes: 15),
        pauseFor: const Duration(seconds: 45),
        onResult: _onSpeechResult,
      );
    }
    if (mounted) setState(() => _isListening = true);
  }

  void _onSpeechResult(result) {
    if (!mounted || !_micArmed) return;
    final words = result.recognizedWords;
    if (words.isEmpty) return;
    setState(() {
      final base = _textBeforeMic ?? '';
      final sep = base.isEmpty || base.endsWith(' ') ? '' : ' ';
      _controller.text = '$base$sep$words'.trimLeft();
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    });
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
      _micArmed = false;
      try {
        await _speech.stop();
      } catch (_) {}
      if (mounted) setState(() => _isListening = false);
      return;
    }

    _textBeforeMic = _controller.text;
    _micArmed = true;
    setState(() => _isListening = true);
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
      _loadMessages();
    }
  }

  void _loadMessages() {
    setState(() {
      _messages = _service.getMessages(widget.conversationId);
    });
    _scrollToBottom(force: true);
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (force || position.pixels >= position.maxScrollExtent - 120) {
        _scrollController.animateTo(
          position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _openLink(String? href) async {
    if (href == null || href.trim().isEmpty) return;
    var raw = href.trim();
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

  Future<void> _showAttachMenu() async {
    if (_isLoading) return;
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
    // Android 13+: photos; mais antigos: storage
    final photos = await Permission.photos.status;
    final storage = await Permission.storage.status;
    if (!photos.isGranted && !photos.isLimited && !storage.isGranted) {
      final p = await Permission.photos.request();
      if (!p.isGranted && !p.isLimited) {
        final s = await Permission.storage.request();
        if (!s.isGranted) {
          _snack('Permissão de galeria necessária');
          return;
        }
      }
    }
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
      final List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.any,
      );
      if (files.isEmpty) return;
      for (final f in files) {
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
    try {
      final processed = await _attachmentService.processFile(path);
      if (!mounted) return;
      setState(() => _attachments.add(processed));
      await LibraryScreen.addEntry(
        name: processed.name,
        kind: processed.kind.name,
        bytes: processed.bytes,
        sourcePath: path,
      );
    } catch (e) {
      _snack('$e');
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

  Future<void> _sendMessage() async {
    final rawText = _controller.text.trim();
    if ((rawText.isEmpty && _attachments.isEmpty) || _isLoading) return;

    // Comandos de memória
    if (rawText.startsWith('/') && _attachments.isEmpty) {
      final handled = await _handleSlashCommand(rawText);
      if (handled) {
        _controller.clear();
        return;
      }
    }

    final pending = List<ProcessedAttachment>.from(_attachments);
    final text = AttachmentService.buildMessageBody(rawText, pending);
    final imagePayload = AttachmentService.buildImagesPayload(pending);
    _attachments.clear();

    final userMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: text,
      conversationId: widget.conversationId,
    );

    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
      _streamPhase = 'thinking';
      _pendingSources = [];
    });

    await _service.addMessage(userMessage);
    _controller.clear();
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
    });

    try {
      final stream = _ollama.chatStream(
        messages: _messages.where((m) => m.content.isNotEmpty).toList(),
        images: imagePayload.isEmpty ? null : imagePayload,
      );

      _streamSubscription = stream.listen(
        (event) {
          if (!mounted) return;

          if (event.phase != null) {
            setState(() => _streamPhase = event.phase!);
          }

          if (event.sources != null && event.sources!.isNotEmpty) {
            _pendingSources = List<WebSource>.from(event.sources!);
          }

          final token = event.token;
          if (token == null) return;

          setState(() {
            _streamPhase = 'typing';
            if (_messages.isNotEmpty && _messages.last.isAssistant) {
              _messages.last.content += token;
            }
          });
          _scrollToBottom();
        },
        onDone: () async {
          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            await _service.addMessage(_messages.last);
          }
          if (mounted) {
            setState(() {
              _isLoading = false;
              _streamPhase = '';
              _pendingSources = [];
            });
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
            _pendingSources = [];
          });
          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            await _service.addMessage(_messages.last);
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
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
    if (!mounted) return;
    final lastMessage = _messages.isNotEmpty ? _messages.last : null;
    if (lastMessage != null &&
        lastMessage.isAssistant &&
        lastMessage.content.isNotEmpty) {
      await _service.addMessage(lastMessage);
    }
    setState(() {
      _isLoading = false;
      _streamPhase = '';
      _pendingSources = [];
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
          decoration: const BoxDecoration(
            color: GamaColors.surface,
            border: Border(
              bottom: BorderSide(color: GamaColors.divider, width: 1),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.menu_rounded,
                      color: GamaColors.textPrimary,
                    ),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                  const Expanded(
                    child: Center(
                      child: Text(
                        'Gamma 1.0',
                        style: TextStyle(
                          color: GamaColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (_isLoading)
                    IconButton(
                      icon: const Icon(
                        Icons.stop_circle_outlined,
                        color: GamaColors.accent,
                      ),
                      tooltip: 'Parar geração',
                      onPressed: _stopGeneration,
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: GamaColors.textSecondary,
                      size: 22,
                    ),
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
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: GamaColors.textSecondary,
                      size: 22,
                    ),
                    tooltip: 'Limpar conversa',
                    onPressed: _clearCurrentConversation,
                  ),
                ],
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
                    opacity: 0.20,
                    child: Center(
                      child: Image.asset(
                        'assets/images/image2.png',
                        width: 280,
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final isUser = msg.isUser;

                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: GestureDetector(
                              onLongPress: () {
                                Clipboard.setData(
                                  ClipboardData(text: msg.content),
                                );
                                _snack('Mensagem copiada');
                              },
                              child: Container(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.82,
                                ),
                                margin: const EdgeInsets.only(bottom: 12),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 11,
                                ),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? GamaColors.bubbleUser
                                      : GamaColors.bubbleAssistant,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(16),
                                    topRight: const Radius.circular(16),
                                    bottomLeft: Radius.circular(
                                      isUser ? 16 : 4,
                                    ),
                                    bottomRight: Radius.circular(
                                      isUser ? 4 : 16,
                                    ),
                                  ),
                                  border: isUser
                                      ? null
                                      : Border.all(color: GamaColors.border),
                                ),
                                child:
                                    msg.content.isEmpty && !isUser && _isLoading
                                    ? const _TypingDots()
                                    : MarkdownBody(
                                        data: msg.content,
                                        // selectable: true impede o clique no link
                                        selectable: false,
                                        shrinkWrap: true,
                                        softLineBreak: true,
                                        onTapLink: (text, href, title) {
                                          _openLink(href);
                                        },
                                        styleSheet: MarkdownStyleSheet(
                                          p: TextStyle(
                                            color: isUser
                                                ? Colors.white
                                                : GamaColors.textPrimary,
                                            fontSize: 15,
                                            height: 1.45,
                                          ),
                                          a: const TextStyle(
                                            color: GamaColors.accent,
                                            decoration:
                                                TextDecoration.underline,
                                          ),
                                          code: TextStyle(
                                            backgroundColor: isUser
                                                ? Colors.black26
                                                : const Color(0xFF2A2A2A),
                                            color: isUser
                                                ? Colors.white
                                                : const Color(0xFFE8E8E8),
                                            fontSize: 13,
                                          ),
                                          codeblockDecoration: BoxDecoration(
                                            color: isUser
                                                ? Colors.black26
                                                : const Color(0xFF2A2A2A),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),

        if (_isLoading)
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _streamPhase == 'searching'
                    ? 'Buscando na web…'
                    : _streamPhase == 'thinking'
                    ? 'Pensando…'
                    : 'Gamma está respondendo…',
                style: const TextStyle(
                  color: GamaColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
          ),

        // Anexos pendentes
        if (_attachments.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            color: GamaColors.surface,
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _attachments.map((a) {
                return Chip(
                  label: Text(a.label, style: const TextStyle(fontSize: 12)),
                  backgroundColor: GamaColors.surfaceCard,
                  side: const BorderSide(color: GamaColors.border),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () {
                    setState(() => _attachments.remove(a));
                  },
                );
              }).toList(),
            ),
          ),

        // Input
        Container(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
          decoration: const BoxDecoration(
            color: GamaColors.surface,
            border: Border(top: BorderSide(color: GamaColors.divider)),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: _isLoading ? null : _toggleListen,
                  tooltip: _isListening ? 'Parar gravação' : 'Falar',
                  icon: Icon(
                    _isListening ? Icons.mic : Icons.mic_none_rounded,
                    color: _isListening
                        ? GamaColors.accent
                        : GamaColors.textSecondary,
                  ),
                ),
                IconButton(
                  onPressed: _isLoading ? null : _showAttachMenu,
                  tooltip: 'Anexar (câmera, galeria, arquivos)',
                  icon: const Icon(
                    Icons.attach_file_rounded,
                    color: GamaColors.textSecondary,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(
                      color: GamaColors.textPrimary,
                      fontSize: 15,
                    ),
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Digite sua mensagem...',
                      hintStyle: const TextStyle(
                        color: GamaColors.textMuted,
                        fontSize: 14,
                      ),
                      filled: true,
                      fillColor: GamaColors.surfaceCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: const BorderSide(color: GamaColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                          color: GamaColors.accent.withOpacity(0.5),
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (_) {
                      if (!_isLoading) _sendMessage();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: _isLoading
                      ? GamaColors.surfaceCard
                      : GamaColors.accent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _isLoading ? null : _sendMessage,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        color: _isLoading ? GamaColors.textMuted : Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ValueChanged<String> onSuggestion;

  const _EmptyState({required this.onSuggestion});

  static const _suggestions = [
    'Anexe ZIP/PDF/código e peça uma análise',
    'Lembre que eu programo em Flutter',
    '/memoria listar',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: GamaColors.accentSoft,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: GamaColors.accent.withOpacity(0.3)),
              ),
              alignment: Alignment.center,
              child: const Text(
                'G',
                style: TextStyle(
                  color: GamaColors.accent,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Como posso te ajudar?',
              style: TextStyle(
                color: GamaColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Anexe código, peça para lembrar algo ou use /memoria',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: GamaColors.textMuted,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            ..._suggestions.map((s) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Material(
                  color: GamaColors.surfaceCard,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    onTap: () => onSuggestion(s),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: GamaColors.border),
                      ),
                      child: Text(
                        s,
                        style: const TextStyle(
                          color: GamaColors.textSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
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
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: GamaColors.textSecondary,
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
