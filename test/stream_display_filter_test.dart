import 'package:flutter_test/flutter_test.dart';
import 'package:gama/utils/stream_display_filter.dart';

void main() {
  test('Retém o payload do ZIP sem exibir o conteúdo interno', () {
    final filter = GamaStreamDisplayFilter();
    final result = <String>[
      filter.append('Começando [[GAMA_'),
      filter.append('FILES]]\npath: exemplo.dart\n````\n') ,
      filter.append('5000 linhas de código' * 1000),
      filter.append('\n````\n[[/GAMA_FILES]] Finalizado.'),
    ].join();
    expect(result, contains('Começando'));
    expect(result, contains('Preparando conteúdo e arquivos'));
    expect(result, contains('Finalizado.'));
    expect(result, isNot(contains('5000 linhas de código')));
  });

  test('Não exibe dados base64 de uma imagem', () {
    final filter = GamaStreamDisplayFilter();
    final result = filter.append('Imagem: [gama_im') +
        filter.append('age]\nmime:image/png\ndata:AAAA') +
        filter.append('BBBBBBBB[/gama_image] concluída');
    expect(result, contains('concluída'));
    expect(result, isNot(contains('AAAA')));
    expect(result, isNot(contains('BBBB')));
  });

  test('Texto comum e reset funcionam normalmente', () {
    final filter = GamaStreamDisplayFilter();
    expect(filter.append('Olá, tudo bem?'), 'Olá, tudo bem?');
    filter.append('[[GAMA_FILES]]conteúdo');
    filter.reset();
    expect(filter.append('Novo chat.'), 'Novo chat.');
  });
}
