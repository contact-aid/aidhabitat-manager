import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Message sérialisable envoyé à l'isolate de compression.
class ImageCompressionWorkerRequest {
  final Uint8List bytes;
  final int maxWidthPx;
  final int jpegQuality;
  final bool fastResize;

  const ImageCompressionWorkerRequest({
    required this.bytes,
    required this.maxWidthPx,
    required this.jpegQuality,
    required this.fastResize,
  });
}

/// Résultat brut du travail CPU. Les décisions métier (fallback, nom et MIME)
/// restent dans `image_compressor.dart` afin de préserver son contrat public.
class ImageCompressionWorkerResult {
  final Uint8List? encodedBytes;
  final bool decoded;

  const ImageCompressionWorkerResult({
    required this.encodedBytes,
    required this.decoded,
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
  if (working.width > request.maxWidthPx) {
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
  );
}
