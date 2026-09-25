import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/message.dart';
import '../services/conversation_service.dart';
import '../services/ollama_service.dart';
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

  List<Message> _messages = [];
  bool _isLoading = false;
  StreamSubscription? _streamSubscription;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _streamSubscription?.cancel();
      _isLoading = false;
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

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    final userMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: text,
      conversationId: widget.conversationId,
    );

    setState(() {
      _messages.add(userMessage);
      _isLoading = true;
    });

    await _service.addMessage(userMessage);
    _controller.clear();
    _scrollToBottom(force: true);

    // Atualiza o título da conversa com a primeira mensagem (estilo ChatGPT)
    final conv = _service.currentConversation;
    if (conv != null && (conv.title == 'Nova conversa' || conv.title.isEmpty)) {
      final shortTitle = text.length > 40
          ? '${text.substring(0, 40)}...'
          : text;
      await _service.renameConversation(widget.conversationId, shortTitle);
    }

    // Mensagem vazia da Gama (vamos preenchendo com o streaming)
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
          if (_messages.isNotEmpty && _messages.last.isAssistant) {
            await _service.addMessage(_messages.last);
          }
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
                  : '${_messages.last.content}\n\n[Erro: $e]';
            }
            _isLoading = false;
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
    });
  }

  Future<void> _clearCurrentConversation() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('Limpar esta conversa?'),
        content: const Text('Isso apaga todas as mensagens desta conversa.'),
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
      // Apaga só as mensagens desta conversa
      final messages = _service.getMessages(widget.conversationId);
      for (final msg in messages) {
        await msg.delete();
      }
      setState(() {
        _messages.clear();
      });
    }
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
    return Column(
      children: [
        // ===== APP BAR =====
        Container(
          color: const Color(0xFF1A1A1A),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  // Botão do Drawer
                  IconButton(
                    icon: const Icon(Icons.menu, color: Colors.white),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                  Expanded(
                    child: Text(
                      _service.currentConversation?.title ?? 'Gamma',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_isLoading)
                    IconButton(
                      icon: const Icon(
                        Icons.stop_circle_outlined,
                        color: Colors.white70,
                      ),
                      tooltip: 'Parar geração',
                      onPressed: _stopGeneration,
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: Colors.white70,
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
                      Icons.delete_outline,
                      color: Colors.white70,
                    ),
                    tooltip: 'Limpar conversa',
                    onPressed: _clearCurrentConversation,
                  ),
                ],
              ),
            ),
          ),
        ),

        // ===== LISTA DE MENSAGENS =====
        Expanded(
          child: _messages.isEmpty
              ? const Center(
                  child: Text(
                    'Como posso te ajudar hoje?',
                    style: TextStyle(color: Colors.white38, fontSize: 16),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
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
                                ? const Color(0xFFFF6B00)
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
                                      fontSize: 15.5,
                                      height: 1.45,
                                    ),
                                    code: const TextStyle(
                                      backgroundColor: Color(0xFF2A2A2A),
                                      color: Color(0xFFE0E0E0),
                                      fontSize: 13.5,
                                    ),
                                    codeblockDecoration: BoxDecoration(
                                      color: const Color(0xFF2A2A2A),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    );
                  },
                ),
        ),

        // ===== INDICADOR "DIGITANDO" =====
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.only(left: 20, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Gamma está digitando...',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
          ),

        // ===== CAMPO DE TEXTO =====
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
                      hintText: 'Fale com a Gamma...',
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
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: _isLoading
                        ? Colors.grey.shade700
                        : const Color(0xFFFF6B00),
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
    );
  }
}
