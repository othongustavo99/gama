import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/widgets/artifact_status_list.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Vídeo gerado oferece ações independentes de reproduzir e baixar',
      (tester) async {
    var downloads = 0;
    var plays = 0;
    const artifact = {
      'artifact_id': 'f123456789abcde0',
      'kind': 'video',
      'filename': 'gama_video_gerado.mp4',
      'size': 1258291,
    };
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ArtifactStatusList(
            artifacts: const [artifact],
            videoPaths: const {},
            onDownload: (_) => downloads++,
            onPlayVideo: (_) => plays++,
            onPreview: (_) {},
          ),
        ),
      ),
    ));
    expect(find.text('Baixar vídeo'), findsOneWidget);
    expect(find.text('Reproduzir'), findsOneWidget);
    await tester.tap(find.text('Baixar vídeo'));
    await tester.pump();
    expect(downloads, 1);
    expect(plays, 0);
    await tester.tap(find.text('Reproduzir'));
    await tester.pump();
    expect(plays, 1);
  });

  testWidgets('ZIP mantém ação normal para baixar arquivo', (tester) async {
    var downloads = 0;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: ArtifactStatusList(
          artifacts: const [
            {'artifact_id': '1234567890abcdef', 'kind': 'zip', 'filename': 'codigo.zip'},
          ],
          videoPaths: const {},
          onDownload: (_) => downloads++,
          onPlayVideo: (_) {},
          onPreview: (_) {},
        ),
      ),
    ));
    expect(find.text('Baixar tudo em ZIP'), findsOneWidget);
    await tester.tap(find.text('Baixar tudo em ZIP'));
    await tester.pump();
    expect(downloads, 1);
  });
}
