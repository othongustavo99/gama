import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';

void main() {
  test('paletas mantêm contraste básico e identidade visual', () {
    final dark = GamaPalette.dark();
    final light = GamaPalette.light();
    expect(dark.background.computeLuminance(), lessThan(0.1));
    expect(light.background.computeLuminance(), greaterThan(0.8));
    expect(light.textPrimary.computeLuminance(), lessThan(0.15));
    expect(light.bubbleUser.computeLuminance(), lessThan(0.25));
    expect(light.accent, isNot(dark.accent));
  });
}
