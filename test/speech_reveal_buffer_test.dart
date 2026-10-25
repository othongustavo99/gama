import 'package:flutter_test/flutter_test.dart';
import 'package:gama/utils/speech_reveal_buffer.dart';

void main() {
  group('SpeechRevealBuffer', () {
    test('does not reveal a whole sentence as soon as audio starts', () {
      final buffer = SpeechRevealBuffer();
      expect(buffer.advance('Olá, tudo bem com você?', 0), '');
      final first = buffer.advance('Olá, tudo bem com você?', 0.30);
      expect(first, isNotEmpty);
      expect(first, isNot('Olá, tudo bem com você?'));
      expect(buffer.advance('Olá, tudo bem com você?', 1),
          'Olá, tudo bem com você?');
    });

    test('preserves completed chunks while continuing the next one', () {
      final buffer = SpeechRevealBuffer();
      buffer.advance('Primeira frase.', 1);
      final part = buffer.advance('Segunda frase de teste.', 0.5);
      expect(part, startsWith('Primeira frase.'));
      expect(part, isNot('Primeira frase. Segunda frase de teste.'));
      expect(buffer.advance('Segunda frase de teste.', 1),
          'Primeira frase. Segunda frase de teste.');
    });

    test('progress never goes backwards or breaks surrogate pairs', () {
      final buffer = SpeechRevealBuffer();
      final first = buffer.advance('Olá 👋 pessoas felizes', 0.65);
      expect(buffer.advance('Olá 👋 pessoas felizes', 0.20), first);
      expect(buffer.advance('Olá 👋 pessoas felizes', 1),
          'Olá 👋 pessoas felizes');
      buffer.reset();
      expect(buffer.value, '');
    });
  });
}
