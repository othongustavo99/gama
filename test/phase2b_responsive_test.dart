import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/responsive_layout.dart';
import 'package:gama/widgets/gama_empty_panel.dart';
import 'package:gama/widgets/gama_section_intro.dart';

void main() {
  test('Oficina acompanha espaço útil, não o sistema operacional', () {
    expect(GamaResponsiveLayout.oficinaColumns(390), 1);
    expect(GamaResponsiveLayout.oficinaColumns(650), 2);
    expect(GamaResponsiveLayout.oficinaColumns(1080), 3);
    expect(GamaResponsiveLayout.oficinaColumns(2000), 3);
    expect(GamaResponsiveLayout.showPersistentSidebar(
      isWindows: true, windowWidth: 700), isFalse);
    expect(GamaResponsiveLayout.showPersistentSidebar(
      isWindows: true, windowWidth: 900), isTrue);
    expect(GamaResponsiveLayout.showPersistentSidebar(
      isWindows: false, windowWidth: 1200), isFalse);
  });

  testWidgets('Estados vazios e títulos suportam larguras móveis', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: Column(children: [
        GamaSectionIntro(title: 'Galeria', description: 'Imagens criadas',
          icon: Icons.image_outlined),
        GamaEmptyPanel(icon: Icons.folder_outlined,
          title: 'Nenhum arquivo', description: 'Crie um arquivo na Oficina.'),
      ]))),
    ));
    expect(find.text('Galeria'), findsOneWidget);
    expect(find.text('Nenhum arquivo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
