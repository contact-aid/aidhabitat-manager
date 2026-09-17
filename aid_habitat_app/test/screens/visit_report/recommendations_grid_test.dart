import 'package:aid_habitat_app/screens/visit_report/recommendations_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web shows five columns when five readable cards fit', () {
    for (final width in [948.0, 1024.0, 1440.0, 1920.0]) {
      expect(recommendationGridColumns(width, isWeb: true), 5);
    }
  });
  test('web reduces columns on narrow viewports', () {
    expect(recommendationGridColumns(947, isWeb: true), 4);
    expect(recommendationGridColumns(700, isWeb: true), 3);
    expect(recommendationGridColumns(400, isWeb: true), 2);
    expect(recommendationGridColumns(320, isWeb: true), 1);
  });
  test('native iPad layout stays at three columns', () {
    for (final width in [700.0, 1024.0, 1440.0]) {
      expect(recommendationGridColumns(width, isWeb: false), 3);
    }
  });
}
