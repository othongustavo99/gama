import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/screens/play_subscription_screen.dart';

void main() {
  testWidgets('plataformas sem Google Play nao oferecem compra ou restauracao',
      (tester) async {
    if (Platform.isAndroid) return; // Esta validacao e para Windows/macOS/Linux.
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [GamaPalette.dark()]),
      home: const PlaySubscriptionScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Assinaturas Gamma'), findsOneWidget);
    expect(find.textContaining('somente no Android'), findsOneWidget);
    final restore = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Restaurar compras'),
    );
    expect(restore.onPressed, isNull);
    expect(find.text('Continuar na Google Play'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
