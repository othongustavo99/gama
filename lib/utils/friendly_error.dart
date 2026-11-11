import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'error_logger.dart';

/// Erro de validação com texto escrito para a interface.
class FriendlyActionException implements Exception {
  const FriendlyActionException(this.message);

  final String message;
}

String friendlyError(Object e, {required String acao}) {
  final intro = 'Não foi possível $acao.';
  if (e is FriendlyActionException) return e.message;

  final code = e is PlatformException ? e.code.toLowerCase() : '';
  final dio = e is DioException ? e : null;
  final status = dio?.response?.statusCode;
  final cause = dio?.error ?? e;
  if (cause is TimeoutException ||
      const {
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      }.contains(dio?.type) ||
      status == 408 ||
      status == 504 ||
      code.contains('timeout')) {
    return '$intro A operação demorou mais que o esperado. Tente de novo.';
  }
  if (cause is SocketException ||
      dio?.type == DioExceptionType.connectionError ||
      const {
        'network_error',
        'network_unavailable',
        'not_connected',
      }.contains(code)) {
    return '$intro Verifique sua conexão com a internet e tente de novo.';
  }

  final fileError = cause is FileSystemException ? cause : null;
  final fileCode = fileError?.osError?.errorCode;
  final accessDenied = fileCode == (Platform.isWindows ? 5 : 13);
  if (status == 403 ||
      accessDenied ||
      RegExp(r'denied|restricted|not_authorized|permission_required')
          .hasMatch(code)) {
    return '$intro Acesso negado. Confira as permissões nas configurações.';
  }
  if (status == 401) {
    return '$intro Entre na sua conta novamente.';
  }
  if (status == 404 ||
      fileCode == 2 ||
      (Platform.isWindows && fileCode == 3) ||
      (fileError?.message.toLowerCase().contains('não encontrado') ?? false) ||
      const {'file_not_found', 'path_not_found'}.contains(code)) {
    return '$intro O arquivo pode ter sido movido ou apagado.';
  }
  return '$intro Tente de novo.';
}

void showFriendlyError(
  BuildContext? context,
  Object error,
  StackTrace stack, {
  required String acao,
  VoidCallback? retry,
  String? prefix,
}) {
  logSwallowed(error, stack, context: acao);
  if (context == null || !context.mounted) return;
  final message = friendlyError(error, acao: acao);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(prefix == null ? message : '$prefix $message'),
      action: retry == null
          ? null
          : SnackBarAction(label: 'Tentar de novo', onPressed: retry),
    ),
  );
}
