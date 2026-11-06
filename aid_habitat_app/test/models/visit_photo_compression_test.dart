import 'dart:typed_data';

import 'package:aid_habitat_app/models/visit_report_categories.dart';
import 'package:aid_habitat_app/services/image_compressor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  for (final tag in <String>[
    kPhotoTagPlanAvant,
    kPhotoTagPlanApres,
    '$kPhotoTagPlanAvant (#1)',
    '$kPhotoTagPlanApres (#12)',
  ]) {
    test('plan section uses doubled bounds: $tag', () {
      final compression = visitPhotoCompressionFor(tag);
      expect(compression.longEdgePx, 960);
      expect(compression.shortEdgePx, 720);
      expect(compression.preserveThinLines, isTrue);
    });
  }

  for (final tag in <String>[
    kPhotoTagLogement,
    kPhotoTagAccessibilite,
    kPhotoTagSanitaires,
    '$kPhotoTagLogement (#2)',
    kPhotoTagAutres,
  ]) {
    test('other photos keep their bounds: $tag', () {
      final compression = visitPhotoCompressionFor(tag);
      expect(compression.longEdgePx, 480);
      expect(compression.shortEdgePx, 360);
      expect(compression.jpegQuality, 74);
      expect(compression.preserveThinLines, isFalse);
    });
  }

  for (final dimensions in <List<int>>[
    [2400, 1800, 960, 720],
    [2480, 3508, 678, 960],
    [640, 480, 640, 480],
  ]) {
    test('imported plan is bounded by plan limits: $dimensions', () async {
      final compression = visitPhotoCompressionFor(kPhotoTagPlanAvant);
      final result = await compressImageForUpload(
        bytes: Uint8List.fromList(
          img.encodePng(img.Image(width: dimensions[0], height: dimensions[1])),
        ),
        fileName: 'plan.png',
        maxLongEdgePx: compression.longEdgePx,
        maxShortEdgePx: compression.shortEdgePx,
        jpegQuality: compression.jpegQuality,
        fastResize: true,
        preserveThinLines: compression.preserveThinLines,
      );
      final decoded = img.decodeImage(result.bytes)!;
      expect(decoded.width, dimensions[2]);
      expect(decoded.height, dimensions[3]);
    });
  }

  test('every thin plan line survives the reduction', () async {
    final compression = visitPhotoCompressionFor(kPhotoTagPlanAvant);
    final plan = img.Image(width: 2480, height: 3508);
    img.fill(plan, color: img.ColorRgb8(255, 255, 255));
    final lineRows = [for (var y = 101; y < 3400; y += 97) y];
    for (final y in lineRows) {
      img.drawLine(
        plan,
        x1: 0,
        y1: y,
        x2: plan.width - 1,
        y2: y,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 2,
      );
    }
    final result = await compressImageForUpload(
      bytes: Uint8List.fromList(img.encodePng(plan)),
      fileName: 'plan.png',
      maxLongEdgePx: compression.longEdgePx,
      maxShortEdgePx: compression.shortEdgePx,
      jpegQuality: compression.jpegQuality,
      fastResize: true,
      preserveThinLines: compression.preserveThinLines,
    );
    final decoded = img.decodeImage(result.bytes)!;
    final scale = decoded.height / plan.height;
    for (final y in lineRows) {
      final center = (y * scale).round();
      final darkest = [
        for (var row = center - 2; row <= center + 2; row++)
          decoded.getPixel(decoded.width ~/ 2, row).r.toInt(),
      ].reduce((a, b) => a < b ? a : b);
      expect(darkest, lessThan(200), reason: 'line at y=$y faded');
    }
  });
}
