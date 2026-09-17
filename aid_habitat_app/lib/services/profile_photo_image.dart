import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

Future<Uint8List> prepareProfilePhoto(Uint8List bytes) =>
    compute(_prepareProfilePhoto, bytes);

Uint8List _prepareProfilePhoto(Uint8List bytes) {
  if (bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('Image trop volumineuse (20 Mo maximum).');
  }
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    throw const FormatException('Image invalide. Utilisez JPEG ou PNG.');
  }
  if (decoded == null) {
    throw const FormatException(
      'Image non prise en charge. Utilisez JPEG ou PNG.',
    );
  }
  final oriented = img.bakeOrientation(decoded);
  final resized = oriented.width <= 400 && oriented.height <= 400
      ? oriented
      : img.copyResize(
          oriented,
          width: oriented.width >= oriented.height ? 400 : null,
          height: oriented.height > oriented.width ? 400 : null,
        );
  for (final quality in [70, 55, 40, 25]) {
    final result = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    if (result.length <= 65000) return result;
  }
  throw const FormatException(
    'Image trop detaillee. Choisissez une autre photo.',
  );
}
