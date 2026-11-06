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
      );
      final decoded = img.decodeImage(result.bytes)!;
      expect(decoded.width, dimensions[2]);
      expect(decoded.height, dimensions[3]);
    });
  }
}
