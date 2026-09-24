import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'settings_screen.dart';
import '../models/message.dart';
import '../services/ollama_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final OllamaService _ollama = OllamaService();

  late Box<Message> _messagesBox;
  List<Message> _messages = [];
  bool _isLoading = false;
  StreamSubscription? _streamSubscription;

  @override
  void initState() {
    super.initState();
    _messagesBox = Hive.box<Message>('messages');
    _loadMessages();
  }

  void _loadMessages() {
    setState(() {
      _messages = _messagesBox.values.toList();
    });
    _scrollToBottom(force: true);
  }

  Future<void> _saveMessage(Message message) async {
    await _messagesBox.add(message);
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      final position = _scrollController.position;
      // Só força o scroll se o usuário já estiver perto do final
      if (force || position.pixels >= position.maxScrollExtent - 120) {
        _scrollController.animateTo(
          position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    final userMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: text,
    );

    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
    });
    await _saveMessage(userMessage);
    _controller.clear();
    _scrollToBottom(force: true);

    // Mensagem vazia da Gama (vamos preenchendo)
    final assistantMessage = Message(
      id: '${DateTime.now().millisecondsSinceEpoch}_ai',
      role: 'assistant',
      content: '',
    );

    setState(() {
      _messages.add(assistantMessage);
    });

    try {
      final stream = _ollama.chatStream(
        messages: _messages.sublist(0, _messages.length - 1),
      );

      _streamSubscription = stream.listen(
        (token) {
          if (!mounted) return;

          setState(() {
            if (_messages.isNotEmpty && _messages.last.isAssistant) {
              _messages.last.content += token;
            }
          });

          _scrollToBottom();
        },
        onDone: () async {
          await _saveMessage(_messages.last);
          if (mounted) {
            setState(() => _isLoading = false);
          }
        },
        onError: (e) async {
          if (!mounted) return;

          final errorMessage = 'Desculpa, deu erro: $e';

          setState(() {
            if (_messages.isNotEmpty && _messages.last.isAssistant) {
              _messages.last.content = _messages.last.content.isEmpty
                  ? errorMessage
                  : '${_messages.last.content}\n\n'
                        '[Erro: $e]';
            }

            _isLoading = false;
          });

          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            await _saveMessage(_messages.last);
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      setState(() {
        _messages.last.content = 'Desculpa, deu erro: $e';
        _isLoading = false;
      });
      await _saveMessage(_messages.last);
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
      await _saveMessage(lastMessage);
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _clearMemory() async {
    await _messagesBox.clear();
    setState(() {
      _messages.clear();
    });
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          'Gama',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        elevation: 0,
        actions: [
          if (_isLoading)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: 'Parar geração',
              onPressed: _stopGeneration,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Configurações',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Limpar memória',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: const Color(0xFF1F1F1F),
                  title: const Text('Limpar memória?'),
                  content: const Text('Isso apaga toda a conversa salva.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancelar'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text(
                        'Apagar',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
                ),
              );

              if (confirm == true) {
                await _clearMemory();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      Clipboard.setData(ClipboardData(text: msg.content));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Mensagem copiada'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.78,
                      ),
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isUser
                            ? const Color(0xFF2563EB)
                            : const Color(0xFF1F1F1F),
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(18),
                          topRight: const Radius.circular(18),
                          bottomLeft: Radius.circular(isUser ? 18 : 4),
                          bottomRight: Radius.circular(isUser ? 4 : 18),
                        ),
                      ),
                      child: msg.content.isEmpty && !isUser && _isLoading
                          ? const Text(
                              '...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                height: 1.4,
                              ),
                            )
                          : MarkdownBody(
                              data: msg.content,
                              selectable: true,
                              styleSheet: MarkdownStyleSheet(
                                p: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  height: 1.4,
                                ),
                                h1: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                                h2: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                                h3: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                                code: TextStyle(
                                  backgroundColor: Colors.black.withValues(
                                    alpha: 0.35,
                                  ),
                                  color: const Color(0xFF7DD3FC),
                                  fontSize: 14,
                                  fontFamily: 'monospace',
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                codeblockPadding: const EdgeInsets.all(12),
                                blockquote: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 16,
                                ),
                                blockquoteDecoration: const BoxDecoration(
                                  border: Border(
                                    left: BorderSide(
                                      color: Color(0xFF2563EB),
                                      width: 3,
                                    ),
                                  ),
                                ),
                                listBullet: const TextStyle(
                                  color: Colors.white,
                                ),
                                strong: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                                em: const TextStyle(
                                  color: Colors.white,
                                  fontStyle: FontStyle.italic,
                                ),
                                a: const TextStyle(
                                  color: Color(0xFF60A5FA),
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'Gama está digitando...',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A1A),
              border: Border(top: BorderSide(color: Color(0xFF2A2A2A))),
            ),
            child: SafeArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(color: Colors.white),
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'Fale com a Gama...',
                        hintStyle: TextStyle(color: Colors.grey.shade500),
                        filled: true,
                        fillColor: const Color(0xFF2A2A2A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (_) {
                        // No mobile, enter cria nova linha.
                        // Só envia se quiser forçar (ou use botão).
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: _isLoading
                          ? Colors.grey.shade700
                          : const Color(0xFF2563EB),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      onPressed: _isLoading ? null : _sendMessage,
                      icon: const Icon(Icons.send_rounded, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
