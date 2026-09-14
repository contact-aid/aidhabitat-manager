// Standalone synthetic browser fixture, never imported by lib/main.dart.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'package:aid_habitat_app/screens/documents_screen.dart';
import 'package:aid_habitat_app/services/document_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final signal = html.PreElement()
    ..id = 'smoke-result'
    ..hidden = true;
  html.document.body!.append(signal);
  try {
    final imageMode = Uri.base.queryParameters['image'] == '1';
    final db = await databaseFactoryFfiWebNoWebWorker.openDatabase(
      'web_pdf_smoke.sqlite',
    );
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    final repository = DocumentRepository(database: local);
    final pdf = pw.Document();
    for (var i = 1; i <= 2; i++) {
      pdf.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(300, 400),
          build: (_) => pw.Text('ORIGINAL PAGE $i'),
        ),
      );
    }
    final photo = img.Image(width: 480, height: 320);
    img.fill(photo, color: img.ColorRgb8(240, 210, 10));
    img.fillRect(photo, x1: 0, y1: 0, x2: 99, y2: 99,
      color: img.ColorRgb8(255, 0, 0));
    final original = imageMode ? img.encodePng(photo) : await pdf.save();
    final mime = imageMode ? 'image/png' : 'application/pdf';
    final png = img.Image(width: 600, height: 400, numChannels: 4);
    img.fillRect(
      png,
      x1: 205,
      y1: 115,
      x2: 220,
      y2: 130,
      color: img.ColorRgba8(255, 0, 0, 255),
    );
    final overlays = jsonEncode({
      '2': 'data:image/png;base64,${base64Encode(img.encodePng(png))}',
    });
    await db.insert('documents', {
      'local_id': 'smoke-pdf',
      'patient_local_id': 'synthetic-patient',
      'title': 'Devis test',
      'file_name': imageMode ? 'image test.png' : 'devis test.pdf',
      'file_ext': imageMode ? 'png' : 'pdf',
      'mime_type': mime,
      'tags_json': '[]',
      'local_file_data_url':
          'data:$mime;base64,${base64Encode(original)}',
      'annotations_json': imageMode ? null : overlays,
      'created_at': '2026-09-09T10:00:00Z',
      'updated_at': '2026-09-09T10:00:00Z',
      'sync_state': 'synced',
    });
    var saves = 0;
    var downloads = 0;
    Future<void> report() async {
      final current = (await repository.fetchDocument('smoke-pdf'))!;
      final decoded = imageMode
          ? img.decodePng(base64Decode(current.dataUrl!.split(',').last))
          : null;
      signal.text = jsonEncode({
        'ready': true,
        'saves': saves,
        'downloads': downloads,
        'dataUrl': current.dataUrl,
        'annotations': current.annotationsJson,
        'operations': (await db.query('sync_operations')).length,
        if (decoded != null) 'dimensions': [decoded.width, decoded.height],
      });
    }

    DocumentRepository.changes.listen((_) {
      saves++;
      unawaited(report());
    });
    html.document.on['smoke-fail'].listen((_) async {
      await db.execute(
        "CREATE TRIGGER fail_pdf BEFORE INSERT ON sync_operations BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      signal.attributes['data-failure-ready'] = 'true';
    });
    html.document.on['smoke-retry'].listen((_) async {
      await db.execute('DROP TRIGGER fail_pdf');
      signal.attributes['data-retry-ready'] = 'true';
    });
    var generation = 0;
    Future<void> openPreview() async {
      runApp(
      MaterialApp(
        home: Scaffold(
          body: DocumentPreview(
            key: ValueKey(generation++),
            doc: (await repository.fetchDocument('smoke-pdf'))!,
            repository: repository,
            onDelete: () {},
            onSave: (_) async {},
            onDownload: () {
              downloads++;
              unawaited(report());
            },
          ),
        ),
      ),
      );
    }
    html.document.on['smoke-reopen'].listen((_) async {
      await openPreview();
      signal.attributes['data-generation'] = '$generation';
    });
    await openPreview();
    await report();
  } catch (error, stack) {
    signal.text = jsonEncode({'error': '$error', 'stack': '$stack'});
  }
}
