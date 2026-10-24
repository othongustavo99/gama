import 'package:flutter_test/flutter_test.dart';
import 'package:gama/utils/speech_sentence_accumulator.dart';

void main() {
  group('SpeechSentenceAccumulator', () {
    test('espera a conclusão de uma frase antes de liberar', () {
      final s = SpeechSentenceAccumulator();
      expect(s.append('Olá, eu sou a Ga'), isEmpty);
      expect(s.append('ma. Como vai você'), ['Olá, eu sou a Gama.']);
      expect(s.finish(), ['Como vai você']);
      expect(s.finish(), isEmpty);
    });

    test('não perde tokens quebrados nem repete frases', () {
      final s = SpeechSentenceAccumulator();
      expect(s.append('Uma frase. Outra fra'), ['Uma frase.']);
      expect(s.append('se! Mais uma? '), ['Outra frase!', 'Mais uma?']);
      expect(s.finish(), isEmpty);
    });

    test('fragmenta texto muito longo somente em espaço', () {
      final s = SpeechSentenceAccumulator();
      final input = ('palavra ' * 70).trim();
      final parts = [...s.append(input), ...s.finish()];
      expect(parts.join(' '), input);
      expect(parts.every((part) => part.length <= 260), isTrue);
    });

    test('cancelamento descarta o texto pendente', () {
      final s = SpeechSentenceAccumulator();
      s.append('Texto ainda incompleto');
      s.clear();
      expect(s.finish(), isEmpty);
    });
  });
}
