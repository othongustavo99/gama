// Testes unitários do app. O teste padrão do `flutter create` (contador) não
// se aplica a este projeto e quebrava `flutter test`.
import 'package:flutter_test/flutter_test.dart';
import 'package:gamma/utils/message_sanitize.dart';

void main() {
  group('MessageSanitize.forApi', () {
    test('troca imagem gerada (base64) por marcador curto', () {
      final out = MessageSanitize.forApi(
        'oi\n[gama_image]\nmime:image/png\ndata:AAAABBBB\n[/gama_image]\ntchau',
      );
      expect(out.contains('AAAABBBB'), isFalse);
      expect(out.contains('imagem gerada'), isTrue);
      expect(out.contains('oi'), isTrue);
      expect(out.contains('tchau'), isTrue);
    });

    test('corta mensagens enormes', () {
      final out = MessageSanitize.forApi('a' * 20000);
      expect(out.length, lessThan(12200));
      expect(out.contains('cortado'), isTrue);
    });

    test('mensagens curtas passam intactas', () {
      expect(MessageSanitize.forApi('  olá  '), 'olá');
    });
  });

  group('MessageSanitize.historyForApi', () {
    test('descarta mensagens vazias', () {
      final out = MessageSanitize.historyForApi([
        {'role': 'user', 'content': 'oi'},
        {'role': 'assistant', 'content': '   '},
      ]);
      expect(out.length, 1);
    });

    test('respeita o orçamento e mantém as mais recentes', () {
      final msgs = [
        for (var i = 0; i < 40; i++)
          {'role': 'user', 'content': 'msg$i ${'x' * 13000}'},
      ];
      final out = MessageSanitize.historyForApi(msgs);
      expect(out.length, lessThan(40));
      expect((out.last['content'] as String).startsWith('msg39'), isTrue);
    });
  });
}
