import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
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

  /// Prepara o texto para fala natural em português:
  /// remove código, tabelas, listas, marcadores ($1, $10), markdown;
  /// expande abreviações e unidades. Resultado = só frases corridas.
  static String plainForSpeech(String text) {
    var t = text;

    // --- Blocos de código (fenced e indentados) ---
    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    t = t.replaceAll(RegExp(r'~~~[\s\S]*?~~~'), ' ');
    t = t.replaceAll(
      RegExp(
        r'^[\t ]{2,}(import |from |def |class |function |const |let |var |public |private |return |if \(|for \(|while \(|#include|package |using ).*$',
        multiLine: true,
      ),
      ' ',
    );

    // Código inline
    t = t.replaceAll(RegExp(r'`[^`]+`'), ' ');

    // --- Artefatos de lista / placeholders do modelo ($1, $10, $2…) ---
    t = t.replaceAll(RegExp(r'\$\d+'), ' ');
    // Marcadores de lista no início de linha: - * • 1. 2)
    t = t.replaceAll(RegExp(r'^[\s]*[-*•]+\s+', multiLine: true), ' ');
    t = t.replaceAll(RegExp(r'^[\s]*\d+[.)]\s+', multiLine: true), ' ');
    // " - " no meio usado como separador de itens → vira ponto
    t = t.replaceAll(RegExp(r'\s+[-–—]\s+'), '. ');

    // --- Tabelas markdown ---
    t = t.replaceAll(RegExp(r'^\|.*\|$', multiLine: true), ' ');
    t = t.replaceAll(
      RegExp(r'^\s*\|?[\s:-]+\|[\s|:-]*$', multiLine: true),
      ' ',
    );

    // --- Imagens e links markdown ---
    t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    t = t.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]*\)'), r'$1');

    // URLs soltas
    t = t.replaceAll(RegExp(r'https?://[^\s)]+', caseSensitive: false), ' ');
    t = t.replaceAll(RegExp(r'www\.[^\s)]+', caseSensitive: false), ' ');

    // --- Markdown / símbolos residuais ---
    t = t.replaceAll(RegExp(r'[#>*_~|{}[\]\\]'), ' ');
    t = t.replaceAll(RegExp(r'-{2,}'), ' ');
    t = t.replaceAll(RegExp(r'/{2,}'), ' ');
    // (mysql2), (gpt-4) etc. — trechos técnicos curtos entre parênteses
    t = t.replaceAll(RegExp(r'\(([a-zA-Z0-9_./+-]{1,24})\)'), ' ');

    // --- Abreviações comuns em português ---
    t = _expandAbbreviations(t);

    // --- Unidades e medidas (1s, 2 min, 3h, 5ms, 10%) ---
    t = _expandUnits(t);

    // Símbolos que o TTS lê mal
    t = t.replaceAll('&', ' e ');
    t = t.replaceAll('@', ' arroba ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Remove trechos que ainda parecem código / lista técnica
    t = _dropCodeySentences(t);

    return t.trim();
  }

  static String _expandAbbreviations(String t) {
    // Ordem importa: formas mais longas primeiro.
    final pairs = <List<String>>[
      [r'\bpor\s+ex\.?\b', 'por exemplo'],
      [r'\bex\.?(?=\s|:|,|$)', 'exemplo'],
      [r'\betc\.?\b', 'etcétera'],
      [r'\bvs\.?\b', 'versus'],
      [r'\bsr\.?\b', 'senhor'],
      [r'\bsra\.?\b', 'senhora'],
      [r'\bdr\.?\b', 'doutor'],
      [r'\bdra\.?\b', 'doutora'],
      [r'\bprof\.?\b', 'professor'],
      [r'\bpág\.?\b', 'página'],
      [r'\bpags?\.?\b', 'páginas'],
      [r'\bn[º°\.]\s*', 'número '],
      [r'\bobs\.?\b', 'observação'],
      [r'\baprox\.?\b', 'aproximadamente'],
      [r'\bmáx\.?\b', 'máximo'],
      [r'\bmín\.?\b', 'mínimo'],
      [r'\bref\.?\b', 'referência'],
      [r'\binfo\.?\b', 'informação'],
      [r'\bconfig\.?\b', 'configuração'],
      [r'\bdoc\.?\b', 'documento'],
      [r'\bfigs?\.?\b', 'figura'],
      [r'\bcap\.?\b', 'capítulo'],
      [r'\bvol\.?\b', 'volume'],
      [r'\bed\.?\b', 'edição'],
      [r'\bi\.?\s*e\.?\b', 'isto é'],
      [r'\bp\.?\s*ex\.?\b', 'por exemplo'],
      [r'\ba\.?\s*C\.?\b', 'antes de Cristo'],
      [r'\bd\.?\s*C\.?\b', 'depois de Cristo'],
      [r'\bkm/h\b', 'quilômetros por hora'],
      [r'\bm/s\b', 'metros por segundo'],
      [r'\bQtd\.?\b', 'quantidade'],
      [r'\bqtd\.?\b', 'quantidade'],
    ];

    for (final p in pairs) {
      t = t.replaceAllMapped(
        RegExp(p[0], caseSensitive: false),
        (_) => p[1],
      );
    }
    return t;
  }

  static String _expandUnits(String t) {
    // 1s / 1 s / 1seg / 1 seg / 1segs → N segundo(s)
    t = t.replaceAllMapped(
      RegExp(
        r'\b(\d+(?:[.,]\d+)?)\s*(segs?|segundos?|s)\b',
        caseSensitive: false,
      ),
      (m) {
        final n = m.group(1)!;
        final unit = (m.group(2) ?? '').toLowerCase();
        // Evita confundir com "s" de outras palavras isoladas só quando
        // claramente unidade de tempo (seg/segs/segundo ou número + s).
        if (unit == 's' || unit.startsWith('seg')) {
          return _pluralUnit(n, 'segundo', 'segundos');
        }
        return m.group(0)!;
      },
    );

    // 2min / 2 min / 2mins
    t = t.replaceAllMapped(
      RegExp(
        r'\b(\d+(?:[.,]\d+)?)\s*(mins?|minutos?)\b',
        caseSensitive: false,
      ),
      (m) => _pluralUnit(m.group(1)!, 'minuto', 'minutos'),
    );

    // 3h / 3 hr / 3 hrs / 3 horas
    t = t.replaceAllMapped(
      RegExp(
        r'\b(\d+(?:[.,]\d+)?)\s*(hrs?|horas?)\b',
        caseSensitive: false,
      ),
      (m) => _pluralUnit(m.group(1)!, 'hora', 'horas'),
    );

    // 5ms / 5 ms
    t = t.replaceAllMapped(
      RegExp(
        r'\b(\d+(?:[.,]\d+)?)\s*(ms|milissegundos?)\b',
        caseSensitive: false,
      ),
      (m) => _pluralUnit(m.group(1)!, 'milissegundo', 'milissegundos'),
    );

    // 10% → 10 por cento
    t = t.replaceAllMapped(
      RegExp(r'(\d+(?:[.,]\d+)?)\s*%'),
      (m) => '${m.group(1)} por cento',
    );

    // 2kb / 5MB / 1GB (leitura aproximada)
    t = t.replaceAllMapped(
      RegExp(
        r'\b(\d+(?:[.,]\d+)?)\s*(kb|mb|gb|tb)\b',
        caseSensitive: false,
      ),
      (m) {
        final n = m.group(1)!;
        switch (m.group(2)!.toLowerCase()) {
          case 'kb':
            return '$n quilobytes';
          case 'mb':
            return '$n megabytes';
          case 'gb':
            return '$n gigabytes';
          case 'tb':
            return '$n terabytes';
          default:
            return m.group(0)!;
        }
      },
    );

    return t;
  }

  static String _pluralUnit(String number, String singular, String plural) {
    final normalized = number.replaceAll(',', '.');
    final value = double.tryParse(normalized);
    if (value == null) return '$number $plural';
    if (value == 1) return '$number $singular';
    return '$number $plural';
  }

  /// Descarta frases que ainda parecem código (muitos símbolos técnicos).
  static String _dropCodeySentences(String t) {
    final parts = t.split(RegExp(r'(?<=[.!?…])\s+'));
    final kept = <String>[];
    for (final p in parts) {
      final s = p.trim();
      if (s.isEmpty) continue;
      final symbols = RegExp(r'[{}\[\]<>;=\\/]').allMatches(s).length;
      final letters = RegExp(r'[A-Za-zÀ-ÿ]').allMatches(s).length;
      if (letters == 0) continue;
      // Se há muitos símbolos em relação às letras, provavelmente é código.
      if (symbols > 3 && symbols * 2 >= letters) continue;
      kept.add(s);
    }
    return kept.join(' ');
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
    _dio.options.headers.addAll(AppConstants.authHeaders);

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
