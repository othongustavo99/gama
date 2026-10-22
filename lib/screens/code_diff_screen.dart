import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/gama_colors.dart';
import '../utils/code_diff.dart';

/// Prévia somente-leitura do código original versus sugestão da Gama.
/// Não aplica patches, não sobrescreve arquivos e não modifica a Biblioteca.
class CodeDiffScreen extends StatelessWidget {
  final String original;
  final String proposed;
  final String language;

  const CodeDiffScreen({
    super.key,
    required this.original,
    required this.proposed,
    required this.language,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.gama;
    final result = compareCode(original, proposed);
    final scheme = Theme.of(context).colorScheme;
    final noAnimations = MediaQuery.of(context).disableAnimations;

    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Prévia das alterações'),
        backgroundColor: p.background,
        actions: [
          IconButton(
            tooltip: 'Copiar código sugerido',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: proposed));
              await HapticFeedback.selectionClick();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Código sugerido copiado')),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1050),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Comparação local • ${language.isEmpty ? 'código' : language}',
                        style: TextStyle(color: p.textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Somente uma prévia. Nenhum arquivo será alterado ou aplicado.',
                        style: TextStyle(color: p.textMuted, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      if (!result.tooLarge)
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            _CountChip(
                              label: '+ ${result.added} adições',
                              color: p.success,
                            ),
                            _CountChip(
                              label: '− ${result.removed} remoções',
                              color: p.error,
                            ),
                            if (!result.hasChanges)
                              _CountChip(
                                label: 'Sem diferenças',
                                color: p.accentCool,
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: result.tooLarge
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'O trecho excede o limite de 600 linhas por versão. '
                              'Para evitar uma comparação parcial enganosa, '
                              'use o botão de copiar para revisar em um editor de código.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: p.textSecondary),
                            ),
                          ),
                        )
                      : Container(
                          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          decoration: BoxDecoration(
                            color: p.surfaceCard,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: p.borderSoft),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListView.builder(
                            physics: noAnimations
                                ? const ClampingScrollPhysics()
                                : const BouncingScrollPhysics(),
                            itemCount: result.lines.length,
                            itemBuilder: (context, index) {
                              final line = result.lines[index];
                              final prefix = switch (line.kind) {
                                CodeDiffKind.added => '+',
                                CodeDiffKind.removed => '−',
                                CodeDiffKind.context => ' ',
                              };
                              final tint = switch (line.kind) {
                                CodeDiffKind.added => p.success,
                                CodeDiffKind.removed => p.error,
                                CodeDiffKind.context => scheme.onSurface,
                              };
                              final bg = line.kind == CodeDiffKind.context
                                  ? Colors.transparent
                                  : tint.withValues(alpha: 0.10);
                              return Container(
                                color: bg,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 3,
                                  horizontal: 10,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 72,
                                      child: Text(
                                        '${line.oldLine ?? ''}  ${line.newLine ?? ''}',
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 10,
                                          color: p.textMuted,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      prefix,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        color: tint,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: SelectableText(
                                        line.text.isEmpty ? ' ' : line.text,
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12,
                                          height: 1.4,
                                          color:
                                              line.kind == CodeDiffKind.context
                                              ? p.textSecondary
                                              : tint,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  final String label;
  final Color color;
  const _CountChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: color.withValues(alpha: .25)),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    child: Text(label, style: TextStyle(fontSize: 12, color: color)),
  );
}
