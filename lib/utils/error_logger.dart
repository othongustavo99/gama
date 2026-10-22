import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Registra exceções em caminhos com fallback silencioso.
/// Não modifica o tratamento do erro nem envia dados para qualquer servidor.
/// Detalhes e stack só são exibidos em builds de desenvolvimento.
void logSwallowed(Object error, StackTrace stack, {String? context}) {
  if (!kDebugMode) return;
  developer.log(
    'Falha recuperável${context == null ? '' : ' ($context)'}',
    name: 'Gama.recoverable',
    error: error,
    stackTrace: stack,
    level: 900,
  );
}
