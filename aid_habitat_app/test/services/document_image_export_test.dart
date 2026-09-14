import 'dart:typed_data';
import 'dart:ui';
import 'package:aid_habitat_app/services/document_image_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Uint8List source() {
    final image = img.Image(width: 120, height: 80);
    img.fill(image, color: img.ColorRgb8(240, 210, 10));
    img.fillRect(
      image,
      x1: 0,
      y1: 0,
      x2: 29,
      y2: 19,
      color: img.ColorRgb8(255, 0, 0),
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  for (final viewport in [const Size(400, 600), const Size(900, 300)]) {
    test(
      'eight saved/reopened rotations retain source pixels at $viewport',
      () async {
        var bytes = source();
        for (var turn = 1; turn <= 8; turn++) {
          bytes = await exportDocumentImage(
            source: bytes,
            viewport: viewport,
            paintInk: (_, _) {},
            quarterTurns: 1,
          );
          final result = img.decodePng(bytes)!;
          expect(result.width, turn.isOdd ? 80 : 120);
          expect(result.height, turn.isOdd ? 120 : 80);
          expect(result.getPixel(result.width ~/ 2, result.height ~/ 2).r, 240);
        }
        expect(img.decodePng(bytes)!.getPixel(5, 5).r, 255);
        expect(img.decodePng(bytes)!.getPixel(5, 5).g, 0);
      },
    );
  }
  test(
    'ink uses fitted-image coordinates, not margins or screen resolution',
    () async {
      final bytes = await exportDocumentImage(
        source: source(),
        viewport: const Size(600, 600),
        paintInk: (canvas, _) {
          canvas.drawCircle(
            const Offset(300, 300),
            30,
            Paint()..color = const Color(0xff0000ff),
          );
          canvas.drawRect(
            const Rect.fromLTWH(0, 0, 600, 50),
            Paint()..color = const Color(0xff00ff00),
          );
        },
        quarterTurns: 1,
      );
      final image = img.decodePng(bytes)!;
      expect((image.width, image.height), (80, 120));
      expect(image.getPixel(40, 60).b, 255);
      expect(image.getPixel(0, 60).r, 240);
    },
  );
  test(
    'invalid image fails instead of reporting a saved blank document',
    () async {
      await expectLater(
        exportDocumentImage(
          source: Uint8List(4),
          viewport: const Size(100, 100),
          paintInk: (_, _) {},
        ),
        throwsA(anything),
      );
    },
  );
}
