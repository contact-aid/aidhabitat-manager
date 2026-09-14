import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';

/// Render original pixels and viewport-normalized ink without exporting the
/// preview's letterboxing, zoom, controls or device pixel ratio.
Future<Uint8List> exportDocumentImage({
  required Uint8List source,
  required Size viewport,
  required void Function(Canvas canvas, Size viewport) paintInk,
  int quarterTurns = 0,
}) async {
  if (viewport.isEmpty) throw StateError('Image pas encore disponible');
  final codec = await ui.instantiateImageCodec(source);
  ui.Image? original;
  ui.Image? output;
  ui.Picture? picture;
  try {
    original = (await codec.getNextFrame()).image;
    final size = Size(original.width.toDouble(), original.height.toDouble());
    final fitted = Alignment.center.inscribe(
      applyBoxFit(BoxFit.contain, size, viewport).destination,
      Offset.zero & viewport,
    );
    final turns = quarterTurns % 4;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    switch (turns) {
      case 1:
        canvas.translate(size.height, 0);
        canvas.rotate(1.5707963267948966);
      case 2:
        canvas.translate(size.width, size.height);
        canvas.rotate(3.141592653589793);
      case 3:
        canvas.translate(0, size.width);
        canvas.rotate(4.71238898038469);
    }
    canvas.clipRect(Offset.zero & size);
    canvas.drawImage(original, Offset.zero, Paint());
    canvas.scale(size.width / fitted.width, size.height / fitted.height);
    canvas.translate(-fitted.left, -fitted.top);
    paintInk(canvas, viewport);
    picture = recorder.endRecording();
    output = await picture.toImage(
      turns.isOdd ? original.height : original.width,
      turns.isOdd ? original.width : original.height,
    );
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Export image impossible');
    return data.buffer.asUint8List();
  } finally {
    output?.dispose();
    picture?.dispose();
    original?.dispose();
    codec.dispose();
  }
}
