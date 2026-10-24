import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gama/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('tema legado continua escuro, e novas preferências são persistentes', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService.instance;
    await settings.init();
    expect(settings.appearance, GamaAppearance.dark);
    expect(settings.reduceMotion, isFalse);
    await settings.setAppearance(GamaAppearance.light);
    await settings.setReduceMotion(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gama_appearance'), 'light');
    expect(prefs.getBool('gama_reduce_motion'), isTrue);
    expect(settings.appearance, GamaAppearance.light);
    expect(settings.reduceMotion, isTrue);
    await settings.setAppearance(GamaAppearance.system);
    expect(settings.appearance, GamaAppearance.system);
  });
}
