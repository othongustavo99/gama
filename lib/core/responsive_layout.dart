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


/// Colunas baseadas na área real disponível e na fonte do usuário.
/// Nunca força duas colunas em celulares muito estreitos.
abstract final class GamaGalleryLayout {
  static int columns(double gridWidth, {double textScale = 1.0}) {
    if (gridWidth <= 0) return 1;
    final idealTileWidth = 168.0 * textScale.clamp(1.0, 1.65);
    // Leva em conta os 12 px de intervalo entre os cartões.
    return ((gridWidth + 12) / (idealTileWidth + 12))
        .floor()
        .clamp(1, 6).toInt();
  }
}
