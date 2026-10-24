import 'package:flutter_test/flutter_test.dart';
import 'package:gama/services/memory_service.dart';

void main() {
  test('memória v3 lê categoria, assunto e fixação sem perder campos antigos', () {
    final record = MemoryFact.fromJson({
      'id': 'xyz', 'text': 'Projeto: Gamma', 'source': 'auto_v3',
      'created_at': '2026-10-24', 'pinned': true,
      'kind': 'project', 'subject': 'Gamma',
    });
    expect(record.pinned, isTrue);
    expect(record.kind, 'project');
    expect(record.subject, 'Gamma');
    expect(record.text, 'Projeto: Gamma');
  });

  test('memórias legadas usam valores padrão sem falhas de parsing', () {
    final record = MemoryFact.fromJson({
      'id': 'old', 'text': 'Nome: Ana', 'source': 'user',
    });
    expect(record.pinned, isFalse);
    expect(record.kind, 'profile');
    expect(record.subject, '');
  });
}
