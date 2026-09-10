import 'dart:typed_data';
import 'package:aid_habitat_app/services/image_rotation_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  for (final turns in [0, 1, 2, 3, 4, 7]) {
    test('worker preserves pixels for $turns quarter turns', () async {
      final original = img.Image(width: 13, height: 7);
      original.setPixelRgba(2, 3, 255, 100, 30, 255);
      final bytes = Uint8List.fromList(img.encodePng(original));
      final actual = await rotateImageToPng(bytes, turns);
      final expected = img.encodePng(
        img.copyRotate(original, angle: (turns % 4) * 90),
      );
      expect(actual, expected);
    });
  }
  test('invalid bytes fail without producing replacement content', () async {
    await expectLater(
      rotateImageToPng(Uint8List.fromList([1, 2]), 1),
      throwsStateError,
    );
  });
}
