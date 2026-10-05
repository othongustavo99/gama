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
  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
    ),
  );

  bool _busy = false;
  bool _cancelQueue = false;

  bool get isBusy => _busy;

  Future<void> stop() async {
    _cancelQueue = true;
    try {
      await _player.stop();
    } catch (_) {}
    _busy = false;
  }

  static String plainForSpeech(String text) {
    var t = text;

    // Nunca envia código ou formatação de programação para o TTS.
    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    t = t.replaceAll(RegExp(r'`[^`]+`'), ' ');

    // Remove tabelas Markdown inteiras. Linhas com barras verticais são
    // conteúdo visual e não fazem sentido em uma resposta falada.
    final lines = t.split(RegExp(r'\r?\n'));
    final spokenLines = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.contains('|')) continue;
      if (RegExp(r'^[-:|\s]+$').hasMatch(trimmed) && trimmed.contains('-')) {
        continue;
      }
      spokenLines.add(line);
    }
    t = spokenLines.join(' ');

    // Markdown que ainda possa ter sobrado.
    t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    t = t.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]*\)'), r'$1');
    t = t.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    t = t.replaceAll(RegExp(r'(^|\s)[>*]+\s*'), r'$1');
    t = t.replaceAll(RegExp(r'(^|\s)[-•]\s+'), r'$1');
    t = t.replaceAll(RegExp(r'[*_~]+'), ' ');

    // URLs e caminhos muito longos não devem ser lidos literalmente.
    t = t.replaceAll(RegExp(r'https?://\S+'), ' ');
    t = t.replaceAll(RegExp(r'www\.\S+'), ' ');

    // Abreviações comuns em respostas escritas.
    final replacements = <RegExp, String>{
      RegExp(r'\bp\.\s*ex\.(?=\s|$)', caseSensitive: false): 'por exemplo',
      RegExp(r'\bex\.(?=\s|$)', caseSensitive: false): 'por exemplo',
      RegExp(r'\betc\.(?=\s|$)', caseSensitive: false): 'e assim por diante',
      RegExp(r'\bobs\.(?=\s|$)', caseSensitive: false): 'observação',
      RegExp(r'\baprox\.(?=\s|$)', caseSensitive: false): 'aproximadamente',
      RegExp(r'\bvs\.(?=\s|$)', caseSensitive: false): 'versus',
      RegExp(r'\bqdo\.(?=\s|$)', caseSensitive: false): 'quando',
      RegExp(r'\bmsg\.(?=\s|$)', caseSensitive: false): 'mensagem',
      RegExp(r'\bconfig\.(?=\s|$)', caseSensitive: false): 'configuração',
      RegExp(r'\binfo\.(?=\s|$)', caseSensitive: false): 'informação',
    };
    replacements.forEach((pattern, replacement) {
      t = t.replaceAll(pattern, replacement);
    });

    // Unidades abreviadas viram palavras completas para a voz.
    t = t.replaceAllMapped(
      RegExp(
        r'(?<!\w)(\d+(?:[.,]\d+)?)\s*(ms|msec|msecs|s|seg|segs|min|mins|m|h|hr|hrs)(?!\w)',
        caseSensitive: false,
      ),
      (m) {
        final number = m.group(1)!;
        final unit = m.group(2)!.toLowerCase();
        final value = double.tryParse(number.replaceAll(',', '.'));
        final singular = value != null && value == 1;
        if (unit == 'ms' || unit == 'msec' || unit == 'msecs') {
          return '$number ${singular ? 'milissegundo' : 'milissegundos'}';
        }
        if (unit == 's' || unit == 'seg' || unit == 'segs') {
          return '$number ${singular ? 'segundo' : 'segundos'}';
        }
        if (unit == 'min' || unit == 'mins' || unit == 'm') {
          return '$number ${singular ? 'minuto' : 'minutos'}';
        }
        return '$number ${singular ? 'hora' : 'horas'}';
      },
    );

    // Alguns símbolos têm leitura ruim no TTS.
    t = t.replaceAll('&', ' e ');
    t = t.replaceAll(RegExp(r'\s*[|{}\[\]<>]+\s*'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

    return t;
  }

  static List<String> sentencesForSpeech(String text) {
    final t = plainForSpeech(text);
    if (t.isEmpty) return [];
    final parts = <String>[];
    final re = RegExp(r'[^.!?…]+[.!?…]+|[^.!?…]+$');
    for (final m in re.allMatches(t)) {
      final s = m.group(0)!.trim();
      if (s.length >= 2) parts.add(s);
    }
    if (parts.isEmpty) return [t];
    final merged = <String>[];
    for (final s in parts) {
      if (merged.isNotEmpty && s.length < 20) {
        merged[merged.length - 1] = '${merged.last} $s';
      } else {
        merged.add(s);
      }
    }
    return merged;
  }

  static String? firstSentence(String text) {
    final list = sentencesForSpeech(text);
    if (list.isEmpty) return null;
    if (list.first.length < 12 && list.length > 1) {
      return '${list[0]} ${list[1]}';
    }
    return list.first.length >= 8 ? list.first : null;
  }

  Future<void> _playBytes(
    Uint8List bytes, {
    FutureOr<void> Function()? onPlaybackStart,
  }) async {
    if (_cancelQueue) return;
    try {
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      if (onPlaybackStart != null) {
        await onPlaybackStart();
      }
      await _player.onPlayerComplete.first.timeout(const Duration(minutes: 5));
    } on TimeoutException {
      // Evita prender a fila indefinidamente se o player não reportar fim.
    }
  }

  Future<Uint8List?> _fetchAudio(String snippet) async {
    final body = <String, dynamic>{'text': snippet, 'format': 'mp3'};
    final voice = SettingsService.instance.fishVoiceId;
    if (voice.isNotEmpty) body['reference_id'] = voice;

    // Reutiliza o mesmo cliente HTTP durante toda a sessão para aproveitar
    // keep-alive e reduzir o custo de cada pedido de TTS.
    _dio.options.baseUrl = SettingsService.instance.baseUrl;

    final res = await _dio.post('/tts', data: body);
    final status = res.statusCode ?? 0;
    if (status >= 400) {
      String detail = 'HTTP $status';
      try {
        final raw = res.data is Uint8List
            ? utf8.decode(res.data as Uint8List, allowMalformed: true)
            : res.data is List
            ? utf8.decode(
                List<int>.from(res.data as List),
                allowMalformed: true,
              )
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
    return bytes;
  }

  Future<void> speak(
    String text, {
    FutureOr<void> Function()? onPlaybackStart,
  }) async {
    final clean = plainForSpeech(text);
    if (clean.isEmpty) return;
    _busy = true;
    _cancelQueue = false;
    try {
      final snippet = clean.length > 900
          ? '${clean.substring(0, 900)}…'
          : clean;
      final bytes = await _fetchAudio(snippet);
      if (bytes == null || _cancelQueue) return;
      await _playBytes(bytes, onPlaybackStart: onPlaybackStart);
    } catch (e, st) {
      debugPrint('TTS erro: $e');
      debugPrintStack(stackTrace: st);
      rethrow;
    } finally {
      _busy = false;
    }
  }

  List<String> _splitLongChunk(String chunk) {
    if (chunk.length <= 900) return [chunk];
    final pieces = <String>[];
    var rest = chunk;
    while (rest.length > 900) {
      var cut = rest.lastIndexOf(' ', 900);
      if (cut < 100) cut = 900;
      pieces.add(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trim();
    }
    if (rest.isNotEmpty) pieces.add(rest);
    return pieces;
  }

  /// Fala o texto inteiro frase a frase.
  ///
  /// Mantém um único áudio sendo reproduzido por vez, mas pré-carrega o
  /// próximo trecho enquanto o atual está tocando. Isso reduz bastante as
  /// pausas entre frases sem alterar a ordem nem a voz.
  Future<void> speakFull(
    String text, {
    FutureOr<void> Function(String chunk)? onChunkPlaybackStart,
  }) async {
    final sentences = sentencesForSpeech(text);
    if (sentences.isEmpty) return;

    final chunks = <String>[];
    for (final sentence in sentences) {
      chunks.addAll(_splitLongChunk(sentence));
    }

    _cancelQueue = false;
    _busy = true;

    try {
      Future<Uint8List?>? nextAudio;

      for (var i = 0; i < chunks.length; i++) {
        if (_cancelQueue) break;

        // O próximo trecho é solicitado enquanto o atual ainda toca.
        nextAudio ??= _fetchAudio(chunks[i]);
        final currentFuture = nextAudio;
        nextAudio = null;

        final bytes = await currentFuture;
        if (bytes == null || _cancelQueue) break;

        // Dispara a preparação do próximo áudio antes de começar a tocar o
        // atual. A chamada roda em paralelo sem bloquear a reprodução.
        if (i + 1 < chunks.length) {
          nextAudio = _fetchAudio(chunks[i + 1]);
        }

        await _playBytes(
          bytes,
          onPlaybackStart: onChunkPlaybackStart == null
              ? null
              : () => onChunkPlaybackStart(chunks[i]),
        );
      }
    } catch (e, st) {
      debugPrint('TTS fila erro: $e');
      debugPrintStack(stackTrace: st);
      rethrow;
    } finally {
      _busy = false;
    }
  }
}
