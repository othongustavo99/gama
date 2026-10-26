/// Pontos de quebra baseados no espaço disponível ao conteúdo,
/// não no sistema operacional ou na largura total do monitor.
abstract final class GamaResponsiveLayout {
  static int oficinaColumns(double availableWidth) {
    final contentWidth = availableWidth > 1180 ? 1180.0 : availableWidth;
    final gridWidth = contentWidth - 48; // margem horizontal do grid
    if (gridWidth >= 960) return 3;
    if (gridWidth >= 600) return 2;
    return 1;
  }

  static bool showPersistentSidebar({
    required bool isWindows,
    required double windowWidth,
  }) => isWindows && windowWidth >= 820;
}
