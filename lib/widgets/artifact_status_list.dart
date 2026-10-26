import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/gama_colors.dart';
import 'generated_files_preview.dart';

class _VideoArtifactPoster extends StatelessWidget {
  final String? duration;
  final String? resolution;
  final VoidCallback onPlay;

  const _VideoArtifactPoster({
    required this.duration,
    required this.resolution,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: Material(
        color: context.gama.surfaceElevated,
        child: InkWell(
          onTap: onPlay,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      context.gama.accentCool.withValues(alpha: 0.32),
                      context.gama.surfaceCard,
                    ],
                  ),
                ),
              ),
              Center(
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  size: 54,
                  color: context.gama.textPrimary,
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 9,
                child: Row(
                  children: [
                    Text(
                      duration == null ? 'Vídeo' : '$duration s',
                      style: TextStyle(
                        color: context.gama.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      resolution ?? '',
                      style: TextStyle(
                        color: context.gama.textPrimary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _InlineVideoPlayer extends StatefulWidget {
  final String path;
  const _InlineVideoPlayer({required this.path});

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.path));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: Video(controller: _controller),
    ),
  );
}

class ArtifactStatusList extends StatelessWidget {
  final List<Map<String, dynamic>> artifacts;
  final ValueChanged<Map<String, dynamic>> onDownload;
  final ValueChanged<Map<String, dynamic>> onPreview;
  final ValueChanged<Map<String, dynamic>> onPlayVideo;
  final Map<String, String> videoPaths;

  const ArtifactStatusList({
    super.key,
    required this.artifacts,
    required this.onDownload,
    required this.onPreview,
    required this.onPlayVideo,
    required this.videoPaths,
  });

  String _validationLabel(Map<String, dynamic> validation) {
    switch (validation['status']?.toString()) {
      case 'passed':
        return 'Validação sintática passou nos formatos suportados';
      case 'partial':
        return 'Validação sintática parcial';
      case 'issues_found':
        return 'Foram encontrados problemas de validação';
      case 'not_checked':
        return 'Código não verificado sintaticamente';
      case 'no_source_files':
        return 'Nenhum arquivo-fonte reconhecido para validação';
      case 'invalid_archive':
        return 'O arquivo não passou na validação estrutural';
      default:
        return 'Validação de código não disponível';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: artifacts
          .map((artifact) {
            final filename =
                artifact['filename']?.toString() ?? 'arquivo gerado';
            final kind = artifact['kind']?.toString() ?? 'zip';
            final structural = artifact['validation'] is Map
                ? Map<String, dynamic>.from(artifact['validation'] as Map)
                : <String, dynamic>{};
            final source = artifact['source_validation'] is Map
                ? Map<String, dynamic>.from(
                    artifact['source_validation'] as Map,
                  )
                : <String, dynamic>{};
            final isZip = kind == 'zip';
            final generatedFiles = artifact['generated_files'] is List
                ? (artifact['generated_files'] as List)
                      .whereType<Map>()
                      .map((file) => Map<String, dynamic>.from(file))
                      .toList()
                : <Map<String, dynamic>>[];
            final isVideo = kind == 'video';
            final artifactId = artifact['artifact_id']?.toString() ?? '';
            final videoPath = videoPaths[artifactId];
            final videoAudioLabel = artifact['audio_generated'] == false
                ? 'sem áudio'
                : 'com áudio';
            // Ausência de laudo (por exemplo, mensagem antiga) não é falha.
            final zipOk = structural['ok'] == true;
            final zipFailed = structural['ok'] == false;
            final syntaxStatus = source['status']?.toString() ?? '';
            final checked = source['checked_count']?.toString() ?? '0';
            final unverified = source['unverified_count']?.toString() ?? '0';
            final issues = source['issue_count']?.toString() ?? '0';

            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: context.gama.surfaceCard.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.gama.borderSoft),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isZip
                            ? Icons.folder_zip_outlined
                            : isVideo
                            ? Icons.movie_outlined
                            : Icons.description_outlined,
                        color: context.gama.accentBright,
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          filename,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.gama.textPrimary,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (isVideo) ...[
                    if (videoPath != null)
                      _InlineVideoPlayer(path: videoPath)
                    else
                      _VideoArtifactPoster(
                        duration: artifact['duration_seconds']?.toString(),
                        resolution: artifact['resolution']?.toString(),
                        onPlay: () => onPlayVideo(artifact),
                      ),
                    const SizedBox(height: 8),
                  ],
                  if (generatedFiles.isNotEmpty) ...[
                    GeneratedFilesPreview(
                      files: generatedFiles,
                      onPreview: onPreview,
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (isZip) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          zipOk
                              ? Icons.check_circle_outline
                              : zipFailed
                              ? Icons.error_outline
                              : Icons.info_outline,
                          size: 16,
                          color: zipFailed
                              ? Colors.orangeAccent
                              : context.gama.accentBright,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            zipOk
                                ? 'ZIP íntegro (estrutura e CRC; execução não testada)'
                                : zipFailed
                                ? 'Integridade do ZIP: falhou'
                                : 'Integridade do ZIP: não informada',
                            style: TextStyle(
                              color: context.gama.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          syntaxStatus == 'passed'
                              ? Icons.verified_outlined
                              : syntaxStatus == 'issues_found'
                              ? Icons.warning_amber_rounded
                              : Icons.info_outline_rounded,
                          size: 16,
                          color: syntaxStatus == 'issues_found'
                              ? Colors.orangeAccent
                              : context.gama.accentBright,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _validationLabel(source),
                            style: TextStyle(
                              color: context.gama.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (source.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        'Arquivos verificados: $checked · não verificados: $unverified · problemas: $issues',
                        style: TextStyle(
                          color: context.gama.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      if (source['note'] is String)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            source['note'].toString(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.gama.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ] else if (isVideo) ...[
                    Text(
                      'Vídeo gerado${artifact['duration_seconds'] == null ? '' : ' · ${artifact['duration_seconds']} s'}${artifact['resolution'] == null ? '' : ' · ${artifact['resolution']}'} · $videoAudioLabel',
                      style: TextStyle(
                        color: context.gama.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ] else ...[
                    Text(
                      structural['ok'] == true
                          ? 'Estrutura do arquivo verificada; conteúdo não testado.'
                          : 'O arquivo precisa de verificação adicional.',
                      style: TextStyle(
                        color: context.gama.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: isVideo
                        ? Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: () => onPlayVideo(artifact),
                                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                                label: const Text('Reproduzir'),
                              ),
                              TextButton.icon(
                                onPressed: () => onDownload(artifact),
                                icon: const Icon(Icons.download_rounded, size: 18),
                                label: const Text('Baixar vídeo'),
                              ),
                            ],
                          )
                        : TextButton.icon(
                            onPressed: () => onDownload(artifact),
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: Text(isZip ? 'Baixar tudo em ZIP' : 'Baixar arquivo'),
                          ),
                  ),
                ],
              ),
            );
          })
          .toList(growable: false),
    );
  }

}
