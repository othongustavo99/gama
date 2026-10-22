import 'dart:convert';

import 'package:hive/hive.dart';

import '../utils/error_logger.dart';

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

  /// Estado de apresentação que precisa sobreviver ao fechamento do app.
  @HiveField(8)
  bool isTruncated;

  @HiveField(9)
  String sourcesJson;

  Message({
    required this.id,
    required this.role,
    required this.content,
    required this.conversationId,
    DateTime? timestamp,
    this.attachmentMetadataJson = '',
    List<String>? variants,
    this.selectedVariantIndex = 0,
    this.isTruncated = false,
    this.sourcesJson = '',
  }) : variants = List<String>.from(
         variants ?? (content.isNotEmpty ? <String>[content] : <String>[]),
       ),
       timestamp = timestamp ?? DateTime.now() {
    if (this.variants.isEmpty && content.isNotEmpty) {
      this.variants.add(content);
      selectedVariantIndex = 0;
    } else if (this.variants.isNotEmpty) {
      if (selectedVariantIndex < 0 ||
          selectedVariantIndex >= this.variants.length) {
        selectedVariantIndex = 0;
      }
      if (content.isNotEmpty) this.variants[selectedVariantIndex] = content;
    }
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  List<Map<String, dynamic>> get sources {
    try {
      final decoded = jsonDecode(sourcesJson);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (error, stack) {
      logSwallowed(error, stack);
      return const [];
    }
  }

  set sources(List<Map<String, dynamic>> value) {
    sourcesJson = jsonEncode(value);
  }

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

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}
