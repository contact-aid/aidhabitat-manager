import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

Future<Uint8List> rotateImageToPng(Uint8List bytes, int quarterTurns) =>
    compute(_rotate, (bytes: bytes, turns: quarterTurns % 4));

Uint8List _rotate(({Uint8List bytes, int turns}) input) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(input.bytes);
  } on RangeError {
    throw StateError('Image incomplete ou non reconnue');
  } on FormatException {
    throw StateError('Image incomplete ou non reconnue');
  }
  if (decoded == null) throw StateError('Format image non reconnu');
  final rotated = img.copyRotate(decoded, angle: input.turns * 90);
  return Uint8List.fromList(img.encodePng(rotated));
}
