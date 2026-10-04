import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';

import 'settings_service.dart';

/// Fala da Gamma via backend → Fish Audio S2.1 Pro.
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final AudioPlayer _player = AudioPlayer();
  bool _busy = false;

  bool get isBusy => _busy;

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
    _busy = false;
  }

  /// Sintetiza e toca. Texto longo é cortado para caber na API.
  Future<void> speak(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    if (_busy) {
      await stop();
    }
    _busy = true;
    try {
      final snippet = clean.length > 1200
          ? '${clean.substring(0, 1200)}…'
          : clean;
      final dio = Dio(
        BaseOptions(
          baseUrl: SettingsService.instance.baseUrl,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 90),
          responseType: ResponseType.bytes,
        ),
      );
      final body = <String, dynamic>{'text': snippet, 'format': 'mp3'};
      final voice = SettingsService.instance.fishVoiceId;
      if (voice.isNotEmpty) body['reference_id'] = voice;

      final res = await dio.post('/tts', data: body);
      final bytes = res.data is Uint8List
          ? res.data as Uint8List
          : Uint8List.fromList(List<int>.from(res.data as List));

      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/gama_tts_${DateTime.now().millisecondsSinceEpoch}.mp3',
      );
      await file.writeAsBytes(bytes, flush: true);
      await _player.play(DeviceFileSource(file.path));
      await _player.onPlayerComplete.first.timeout(
        const Duration(minutes: 3),
        onTimeout: () {},
      );
    } finally {
      _busy = false;
    }
  }
}
