import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/image_reference_intent.dart';

void main() {
  group('Oficina: criação não depende de imagem anterior', () {
    for (final prompt in <String>[
      'Faz assim, crie uma foto sua em versão humana',
      'Crie uma versão humana da Gamma',
      'Gere uma foto de Saturno em versão futurista',
      'Crie uma variação original de uma cidade cyberpunk',
      'Transforme minha ideia em uma ilustração',
      'Desenhe uma versão minimalista de uma floresta',
      'Uma foto realista de uma mulher fictícia',
      'Faz uma imagem mais minimalista de Saturno',
    ]) {
      test(prompt, () {
        expect(ImageReferenceIntent.requiresPreviousImage(prompt), isFalse);
      });
    }
  });

  group('Oficina: edições realmente dependem de imagem', () {
    for (final prompt in <String>[
      'Edite esta imagem',
      'Crie outra versão dessa imagem em anime',
      'Transforme a imagem anterior em desenho',
      'Remova o fundo da foto anterior',
      'Melhore esta foto',
      'Mude a cor dela',
      'Refaça a última imagem com fundo azul',
      'Adicione estrelas nessa imagem',
      'Faz um pouco mais simples e minimalista',
      'Deixa mais clean e elegante',
      'Troca a cor do fundo',
      'Muda a paleta para azul',
    ]) {
      test(prompt, () {
        expect(ImageReferenceIntent.requiresPreviousImage(prompt), isTrue);
      });
    }
  });

  test('Pergunta conceitual não inicia edição', () {
    expect(
      ImageReferenceIntent.requiresPreviousImage('Como editar uma imagem?'),
      isFalse,
    );
  });
}
