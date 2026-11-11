import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/screens/settings_screen.dart';
import 'package:gama/screens/images_screen.dart';
import 'package:gama/services/identity_service.dart';
import 'package:gama/utils/local_file_metadata.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  double contrast(Color a, Color b) {
    final aLuminance = a.computeLuminance();
    final bLuminance = b.computeLuminance();
    final high = aLuminance > bLuminance ? aLuminance : bLuminance;
    final low = aLuminance > bLuminance ? bLuminance : aLuminance;
    return (high + .05) / (low + .05);
  }

  test('texto e ícones sobre ação laranja têm contraste AA', () {
    for (final palette in [GamaPalette.dark(), GamaPalette.light()]) {
      expect(contrast(palette.accent, palette.onAccent), greaterThan(4.5));
    }
  });

  test('metadados locais são lidos fora dos builders, inclusive ausências', () async {
    final dir = await Directory.systemTemp.createTemp('gamma-phase1-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}imagem.png');
    await file.writeAsBytes([1, 2, 3, 4]);
    final absent = '${dir.path}${Platform.pathSeparator}ausente.png';
    final result = await loadLocalFileMetadata([
      {'path': file.path},
      {'path': file.path},
      {'path': absent},
      {'name': 'Sem arquivo'},
    ], batchSize: 1);
    expect(result.length, 2);
    expect(result[file.path]?.exists, isTrue);
    expect(result[file.path]?.bytes, 4);
    expect(result[file.path]?.hasContent, isTrue);
    expect(result[absent]?.hasContent, isFalse);
  });

  testWidgets('Conta abre perfil antes de oferecer exclusão', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await IdentityService.instance.init();
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.tap(find.text('Conta'));
    await tester.pumpAndSettle();
    expect(find.text('Conta e privacidade'), findsOneWidget);
    expect(find.text('SEUS DADOS'), findsOneWidget);
    expect(find.text('Solicitar exclusão da conta'), findsOneWidget);
    expect(find.text('Digite EXCLUIR para confirmar'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Galeria mostra título em telefone estreito', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await IdentityService.instance.init();
    await tester.pumpWidget(const MaterialApp(home: ImagesScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Galeria'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
