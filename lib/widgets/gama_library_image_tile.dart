import 'dart:io';

import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../core/design_tokens.dart';

/// Cartão de imagem único para Biblioteca e Galeria.
/// Recebe o estado do arquivo já consultado fora do build.
class GamaLibraryImageTile extends StatelessWidget {
  const GamaLibraryImageTile({
    super.key,
    required this.name,
    required this.path,
    required this.available,
    required this.cacheWidth,
    required this.onOpen,
    this.onDownload,
    this.onRemove,
    this.selectionMode = false,
    this.selected = false,
    this.onSelect,
  });

  final String name;
  final String? path;
  final bool available;
  final int cacheWidth;
  final VoidCallback onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onRemove;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    final canOpen = available && path != null && path!.isNotEmpty;
    final image = canOpen
        ? Image.file(
            File(path!),
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            semanticLabel: name,
            errorBuilder: (_, __, ___) => _UnavailableImage(name: name),
          )
        : _UnavailableImage(name: name);

    return Material(
      color: g.surfaceCard,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: selectionMode ? onSelect : (canOpen ? onOpen : null),
        onLongPress: onSelect,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  image,
                  if (selectionMode)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: g.surface.withValues(alpha: 0.92),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(7),
                            child: Icon(
                              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                              size: 24,
                              color: selected ? g.accent : g.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!selectionMode && canOpen && onDownload != null)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Material(
                        color: g.surface.withValues(alpha: 0.94),
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Baixar $name',
                          icon: const Icon(Icons.download_rounded),
                          onPressed: onDownload,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: g.textPrimary,
                                fontSize: GamaType.label,
                                fontWeight: FontWeight.w600)),
                        if (!canOpen)
                          Text('Indisponível neste dispositivo',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: g.textMuted, fontSize: GamaType.caption)),
                      ],
                    ),
                  ),
                  if (selectionMode)
                    const SizedBox(width: 8)
                  else if (onRemove != null)
                    PopupMenuButton<String>(
                      tooltip: 'Opções de $name',
                      onSelected: (action) {
                        if (action == 'download') onDownload?.call();
                        if (action == 'remove') onRemove?.call();
                      },
                      itemBuilder: (_) => [
                        if (canOpen && onDownload != null)
                          const PopupMenuItem(value: 'download', child: Text('Baixar')),
                        const PopupMenuItem(value: 'remove', child: Text('Remover')),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnavailableImage extends StatelessWidget {
  const _UnavailableImage({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: context.gama.surfaceElevated,
        child: Center(
          child: Semantics(
            label: 'Imagem $name indisponível neste dispositivo',
            child: Icon(
              Icons.image_not_supported_outlined,
              size: 32,
              color: context.gama.textMuted,
            ),
          ),
        ),
      );
}
