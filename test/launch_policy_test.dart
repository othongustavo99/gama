import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/launch_policy.dart';

void main() {
  test('login anônimo vem desativado por padrão no app comercial', () {
    // Nas execuções padrão de teste sem dart-define, o botão não é exibido.
    expect(GamaLaunchPolicy.guestLoginEnabled, isFalse);
  });
}
