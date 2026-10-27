import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/widgets/gama_floating_page.dart';

void main() {
  testWidgets('Navegação flutuante preserva ações sem AppBar', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GamaFloatingPage(
          actions: [
            IconButton(
              tooltip: 'Atualizar',
              onPressed: () => refreshed++,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          child: const Center(child: Text('Conteúdo da tela')),
        ),
      ),
    ));

    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Conteúdo da tela'), findsOneWidget);
    expect(find.byTooltip('Voltar'), findsOneWidget);
    await tester.tap(find.byTooltip('Atualizar'));
    expect(refreshed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Controles e abas não transbordam em telas estreitas',
      (tester) async {
    tester.view.physicalSize = const Size(340, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          body: GamaFloatingPage(
            actions: [
              IconButton(tooltip: 'Atualizar', onPressed: null,
                  icon: Icon(Icons.refresh)),
              IconButton(tooltip: 'Mais opções', onPressed: null,
                  icon: Icon(Icons.more_vert)),
            ],
            tabs: TabBar(tabs: [
              Tab(icon: Icon(Icons.analytics_outlined)),
              Tab(icon: Icon(Icons.manage_accounts_outlined)),
            ]),
            child: TabBarView(children: [
              Center(child: Text('Métricas')),
              Center(child: Text('Planos')),
            ]),
          ),
        ),
      ),
    ));

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
