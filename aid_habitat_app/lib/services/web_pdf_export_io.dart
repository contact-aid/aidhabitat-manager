import 'dart:typed_data';

Future<void> prepareWebPdfExport() async {}

Future<Uint8List> exportWebPdfImpl(
  Uint8List source,
  Map<String, Object> pages,
  int quarterTurns,
) => Future.error(UnsupportedError('Export PDF web uniquement'));
