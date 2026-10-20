import 'package:shared_preferences/shared_preferences.dart';

import 'local_notification_service.dart';

/// Fonte única para os toggles da tela Plugins.
/// Mantém o formato de armazenamento já usado pelo app para não perder
/// preferências existentes em atualizações.
class PluginSettingsService {
  PluginSettingsService._();
  static final PluginSettingsService instance = PluginSettingsService._();

  static const String prefsKey = 'gama_plugin_toggles';
  static const Map<String, bool> defaults = <String, bool>{
    'web_search': true,
    'memory': true,
    'attachments': true,
    'vision': true,
    'code_analyzer': true,
    'tts': true,
    'scheduled': true,
  };

  Future<Map<String, bool>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(prefsKey) ?? const <String>[];
    final result = Map<String, bool>.from(defaults);
    for (final entry in stored) {
      final split = entry.split('=');
      if (split.length == 2 && result.containsKey(split[0])) {
        result[split[0]] = split[1] == '1';
      }
    }
    return result;
  }

  Future<bool> isEnabled(String id) async {
    final settings = await load();
    return settings[id] ?? true;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final settings = await load();
    if (!settings.containsKey(id)) return;
    settings[id] = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      prefsKey,
      settings.entries.map((e) => '${e.key}=${e.value ? '1' : '0'}').toList(),
    );

    if (id == 'scheduled') {
      // A desativação cancela notificações pendentes, mas conserva os
      // lembretes locais. Ao reativar, os lembretes futuros são reagendados.
      try {
        if (enabled) {
          await LocalNotificationService.instance.requestPermission();
        }
        await LocalNotificationService.instance.syncSavedReminders(
          enabled: enabled,
        );
      } catch (_) {
        // Configuração da tela não pode falhar por incompatibilidade local.
      }
    }
  }
}
