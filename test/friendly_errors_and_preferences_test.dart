import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/services/plugin_settings_service.dart';
import 'package:gama/utils/friendly_error.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Erros de ação explicam o que fazer sem expor detalhes', () {
    const action = 'abrir o arquivo';
    const secret = 'caminho-interno-privado';
    final errors = <Object, String>{
      TimeoutException(secret): 'demorou mais que o esperado',
      const SocketException(secret): 'conexão com a internet',
      PlatformException(code: 'camera_access_denied', message: secret):
          'Acesso negado',
      const FileSystemException('Arquivo não encontrado', secret):
          'pode ter sido movido ou apagado',
      StateError(secret): 'Tente de novo',
    };
    for (final entry in errors.entries) {
      final message = friendlyError(entry.key, acao: action);
      expect(message, contains(action));
      expect(message, contains(entry.value));
      expect(message, isNot(contains(secret)));
    }
  });

  test(
    'Preferências legadas só podem desativar os recursos opcionais',
    () async {
      SharedPreferences.setMockInitialValues({
        PluginSettingsService.prefsKey: [
          'attachments=0',
          'vision=0',
          'code_analyzer=0',
          'web_search=0',
          'memory=0',
          'tts=0',
          'scheduled=0',
        ],
      });

      final service = PluginSettingsService.instance;
      final settings = await service.load();
      for (final feature in ['attachments', 'vision', 'code_analyzer']) {
        expect(settings[feature], isTrue);
        await service.setEnabled(feature, false);
        expect(await service.isEnabled(feature), isTrue);
      }
      for (final preference in ['web_search', 'memory', 'tts', 'scheduled']) {
        expect(settings[preference], isFalse);
      }
    },
  );
}
