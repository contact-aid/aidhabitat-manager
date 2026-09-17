import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:aid_habitat_app/services/profile_photo_image.dart';

void main() {
  for (final size in [(300, 1200), (1200, 300), (40, 40)]) {
    test('profile JPEG fits both dimensions for $size', () async {
      final input = Uint8List.fromList(
        img.encodePng(img.Image(width: size.$1, height: size.$2)),
      );
      final result = await prepareProfilePhoto(input);
      final decoded = img.decodeJpg(result)!;
      expect(decoded.width, lessThanOrEqualTo(400));
      expect(decoded.height, lessThanOrEqualTo(400));
      expect(result.length, lessThanOrEqualTo(65000));
    });
  }
  test('invalid images are rejected before enqueueing', () async {
    await expectLater(
      prepareProfilePhoto(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
