import 'dart:typed_data';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Message sérialisable envoyé à l'isolate de compression.
class ImageCompressionWorkerRequest {
  final Uint8List bytes;
  final int maxWidthPx;
  final int? maxLongEdgePx;
  final int? maxShortEdgePx;
  final int jpegQuality;
  final bool fastResize;
  final bool preserveThinLines;

  const ImageCompressionWorkerRequest({
    required this.bytes,
    required this.maxWidthPx,
    this.maxLongEdgePx,
    this.maxShortEdgePx,
    required this.jpegQuality,
    required this.fastResize,
    this.preserveThinLines = false,
  });
}

/// Résultat brut du travail CPU. Les décisions métier (fallback, nom et MIME)
/// restent dans `image_compressor.dart` afin de préserver son contrat public.
class ImageCompressionWorkerResult {
  final Uint8List? encodedBytes;
  final bool decoded;
  final bool resized;

  const ImageCompressionWorkerResult({
    required this.encodedBytes,
    required this.decoded,
    this.resized = false,
  });
}

/// Callback top-level requis par `compute`.
///
/// Sur iOS, macOS et les autres cibles natives, Flutter exécute ce callback
/// dans un isolate distinct. Sur le web, `compute` reste compatible mais
/// s'exécute sur l'event loop principal.
ImageCompressionWorkerResult compressImageInWorker(
  ImageCompressionWorkerRequest request,
) {
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null) {
    return const ImageCompressionWorkerResult(
      encodedBytes: null,
      decoded: false,
    );
  }

  img.Image working = decoded;
  var resized = false;
  if (request.maxLongEdgePx != null && request.maxShortEdgePx != null) {
    working = img.bakeOrientation(working);
    final longEdge = math.max(working.width, working.height);
    final shortEdge = math.min(working.width, working.height);
    final scale = math.min(
      1.0,
      math.min(
        request.maxLongEdgePx! / longEdge,
        request.maxShortEdgePx! / shortEdge,
      ),
    );
    if (scale < 1) {
      working = img.copyResize(
        working,
        width: math.max(1, (working.width * scale).floor()),
        height: math.max(1, (working.height * scale).floor()),
        // Linear and cubic sample a few pixels, so a thin plan line can vanish.
        interpolation: request.preserveThinLines
            ? img.Interpolation.average
            : request.fastResize
            ? img.Interpolation.linear
            : img.Interpolation.cubic,
      );
      resized = true;
    }
  } else if (working.width > request.maxWidthPx) {
    working = img.copyResize(
      working,
      width: request.maxWidthPx,
      interpolation: request.fastResize
          ? img.Interpolation.linear
          : img.Interpolation.cubic,
    );
  }

  return ImageCompressionWorkerResult(
    encodedBytes: Uint8List.fromList(
      img.encodeJpg(working, quality: request.jpegQuality),
    ),
    decoded: true,
    resized: resized,
  );
}
