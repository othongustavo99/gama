import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'settings_service.dart';

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

  static String plainForSpeech(String text) {
    var t = text;
    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    t = t.replaceAll(RegExp(r'`[^`]+`'), ' ');
    t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    t = t.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]*\)'), r'$1');
    t = t.replaceAll(RegExp(r'[#>*_~]'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// Primeira frase “completa” para começar a falar cedo.
  static String? firstSentence(String text) {
    final t = plainForSpeech(text);
    if (t.length < 12) return null;
    final m = RegExp(r'^(.+?[.!?…])(\s|$)').firstMatch(t);
    if (m != null) {
      final s = m.group(1)!.trim();
      if (s.length >= 12) return s;
    }
    // fallback: primeiros ~180 chars em espaço
    if (t.length >= 80) {
      final cut = t.substring(0, t.length > 180 ? 180 : t.length);
      final sp = cut.lastIndexOf(' ');
      return sp > 40 ? cut.substring(0, sp) : cut;
    }
    return null;
  }

  Future<void> speak(String text) async {
    final clean = plainForSpeech(text);
    if (clean.isEmpty) return;
    if (_busy) await stop();
    _busy = true;
    try {
      final snippet =
          clean.length > 900 ? '${clean.substring(0, 900)}…' : clean;

      final dio = Dio(
        BaseOptions(
          baseUrl: SettingsService.instance.baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );

      final body = <String, dynamic>{
        'text': snippet,
        'format': 'mp3',
      };
      final voice = SettingsService.instance.fishVoiceId;
      if (voice.isNotEmpty) body['reference_id'] = voice;

      final res = await dio.post('/tts', data: body);
      final status = res.statusCode ?? 0;

      if (status >= 400) {
        String detail = 'HTTP $status';
        try {
          final raw = res.data is Uint8List
              ? utf8.decode(res.data as Uint8List, allowMalformed: true)
              : res.data is List
                  ? utf8.decode(List<int>.from(res.data as List),
                      allowMalformed: true)
                  : '${res.data}';
          detail = raw.length > 280 ? raw.substring(0, 280) : raw;
        } catch (_) {}
        throw Exception(detail);
      }

      final Uint8List bytes = res.data is Uint8List
          ? res.data as Uint8List
          : Uint8List.fromList(List<int>.from(res.data as List));

      if (bytes.length < 100) {
        throw Exception('Áudio inválido (${bytes.length} bytes)');
      }

      await _player.stop();
      // play retorna quando começa — não espera o áudio inteiro baixar de novo
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
    } catch (e, st) {
      debugPrint('TTS erro: $e');
      debugPrintStack(stackTrace: st);
      rethrow;
    } finally {
      _busy = false;
    }
  }
}
