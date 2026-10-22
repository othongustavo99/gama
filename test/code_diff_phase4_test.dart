import 'package:flutter_test/flutter_test.dart';
import 'package:gama/utils/code_diff.dart';

void main() {
  group('Fase 4: prévia de alterações da Oficina', () {
    test('nenhuma diferença para versões idênticas', () {
      final result = compareCode('void main() {}', 'void main() {}');
      expect(result.tooLarge, isFalse);
      expect(result.hasChanges, isFalse);
      expect(result.lines.single.kind, CodeDiffKind.context);
    });

    test('inclusão identifica a linha adicionada sem alterar a original', () {
      const original = 'a\nb';
      const updated = 'a\nnovo\nb';
      final result = compareCode(original, updated);
      expect(result.added, 1);
      expect(result.removed, 0);
      expect(
        result.lines
            .where((line) => line.kind == CodeDiffKind.added)
            .single
            .text,
        'novo',
      );
      expect(original, 'a\nb');
    });

    test('remoção indica números do arquivo de origem', () {
      final result = compareCode('a\nremover\nb', 'a\nb');
      expect(result.added, 0);
      expect(result.removed, 1);
      final removed = result.lines.singleWhere(
        (line) => line.kind == CodeDiffKind.removed,
      );
      expect(removed.text, 'remover');
      expect(removed.oldLine, 2);
      expect(removed.newLine, isNull);
    });

    test('substituição é mostrada como inclusão e remoção', () {
      final result = compareCode('x', 'y');
      expect(result.added, 1);
      expect(result.removed, 1);
    });

    test('normaliza finais de linha Windows antes de comparar', () {
      final result = compareCode('a\r\nb', 'a\nb');
      expect(result.hasChanges, isFalse);
    });

    test('recusa arquivo grande em vez de esconder mudanças', () {
      final original = List.filled(601, 'a').join('\n');
      final result = compareCode(original, 'outro');
      expect(result.tooLarge, isTrue);
      expect(result.lines, isEmpty);
    });

    test('limite reduzido pode ser injetado nos testes', () {
      final result = compareCode('a\nb\nc', 'a', maxLinesPerSide: 2);
      expect(result.tooLarge, isTrue);
    });
  });
}
