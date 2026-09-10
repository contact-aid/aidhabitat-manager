import 'dart:convert';
import 'dart:typed_data';

import 'package:aid_habitat_app/services/web_pdf_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Uint8List fixture() {
    final image = img.Image(width: 600, height: 400, numChannels: 4);
    img.fillRect(
      image,
      x1: 150,
      y1: 0,
      x2: 449,
      y2: 399,
      color: img.ColorRgba8(255, 255, 255, 255),
    );
    img.fillRect(
      image,
      x1: 205,
      y1: 115,
      x2: 215,
      y2: 125,
      color: img.ColorRgba8(255, 0, 0, 255),
    );
    return img.encodePng(image);
  }

  test('all historical pages are decoded, including unvisited ones', () {
    final url = 'data:image/png;base64,${base64Encode(fixture())}';
    final pages = decodeWebPdfOverlays(jsonEncode({'1': url, '4': url}));
    expect(pages.keys, [1, 4]);
    expect(pages[4]!.legacyViewport, isTrue);
    expect(pages[1]!.bytes, fixture());
    expect(decodeWebPdfOverlays(null), isEmpty);
    expect(decodeWebPdfOverlays('{}'), isEmpty);
  });

  for (final raw in [
    'broken',
    '[]',
    '{"0":"x"}',
    '{"1":"data:image/png;base64,AAAA"}',
    '{"01":"x"}',
  ]) {
    test('invalid overlays fail instead of being silently discarded: $raw', () {
      expect(() => decodeWebPdfOverlays(raw), throwsFormatException);
    });
  }

  test(
    'legacy centered margins are removed and ink stays in page coordinates',
    () async {
      final source = fixture();
      final bytes = await normalizeLegacyWebPdfPage(source, 0.75);
      final image = img.decodePng(bytes)!;
      expect(image.width, 300);
      expect(image.height, 400);
      final pixel = image.getPixel(60, 120);
      expect(pixel.r, greaterThan(220));
      expect(pixel.g, lessThan(30));
      expect(source, fixture());
    },
  );

  test(
    'invalid geometry does not attempt to convert a historical page',
    () async {
      await expectLater(
        normalizeLegacyWebPdfPage(fixture(), 0),
        throwsArgumentError,
      );
    },
  );
}
