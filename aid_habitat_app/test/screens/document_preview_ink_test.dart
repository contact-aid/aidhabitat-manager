import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:aid_habitat_app/screens/documents_screen.dart';
import 'package:aid_habitat_app/services/document_repository.dart';
import 'package:aid_habitat_app/services/document_revision_store.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfx/src/renderer/interfaces/platform.dart';
import 'package:pdfx/src/renderer/io/platform_method_channel.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final failAt in ['none', 'native', 'queue']) {
    testWidgets(
      'PDF ink publication ($failAt) keeps all pages and retries safely',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final previousRenderer = PdfxPlatform.instance;
        // Rendering is simulated here; real PDFKit geometry/pixels are covered
        // by tool/pdf_ink_native_test.swift.
        PdfxPlatform.instance = PdfxPlatformMethodChannel();
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        late Directory root;
        late Database db;
        late File original;
        late File previewPng;
        late DocumentRepository repository;
        const now = '2026-09-09T10:00:00.000Z';
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('preview-ink-');
          db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
          final local = LocalDatabase.forTesting(db);
          await local.createSchemaForTesting();
          original = await File(
            p.join(root.path, 'source.pdf'),
          ).writeAsString('original PDF');
          final image = img.Image(width: 300, height: 400);
          img.fill(image, color: img.ColorRgb8(255, 255, 255));
          previewPng = await File(
            p.join(root.path, 'render.png'),
          ).writeAsBytes(img.encodePng(image));
          // Legacy ink on an unvisited page must be included too.
          for (final page in [1, 2]) {
            await File(
              '${original.path}.page$page.png.annotation.json',
            ).writeAsString(
              jsonEncode([
                {
                  'tool': 'pen',
                  'color': 0xff111827,
                  'strokeWidth': 2.0,
                  'points': [
                    [0.45, 0.3],
                    [0.55, 0.5],
                  ],
                },
              ]),
            );
          }
          await db.insert('documents', {
            'local_id': 'doc',
            'patient_local_id': 'patient',
            'title': 'Devis',
            'file_name': 'devis sdb.pdf',
            'file_ext': 'pdf',
            'mime_type': 'application/pdf',
            'local_file_path': original.path,
            'tags_json': '[]',
            'created_at': now,
            'updated_at': now,
            'sync_state': 'synced',
          });
          repository = DocumentRepository(
            database: local,
            revisionStore: DocumentRevisionStore(
              documentsDirectory: () async => root,
            ),
          );
        });
        final writes = <Map<dynamic, dynamic>>[];
        final outputPaths = <String>[];
        var shouldFail = failAt != 'none';
        var renderCount = 0;
        final nativeCalls = <String>[];
        var downloaded = false;
        const inkChannel = MethodChannel('aidhabitat/pdf_rotation');
        const rendererChannel = MethodChannel('io.scer.pdf_renderer');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          rendererChannel,
          (call) async {
            nativeCalls.add(call.method);
            if (call.method == 'open.document.file') {
              return {'id': 'pdf', 'pagesCount': 2};
            }
            if (call.method == 'open.page') {
              return {'id': 'page', 'width': 600.0, 'height': 800.0};
            }
            return null;
          },
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          inkChannel,
          (call) async {
            nativeCalls.add(call.method);
            if (call.method == 'readPdfInk') return {'pages': {}};
            if (call.method == 'renderPdfInkPreview') {
              renderCount++;
              expect(call.arguments['omitManagedInk'], isTrue);
              return previewPng.path;
            }
            if (call.method == 'writePdfInk') {
              writes.add(Map.of(call.arguments));
              if (shouldFail && failAt == 'native') {
                throw PlatformException(code: 'disk_full');
              }
              final output = await File(
                p.join(root.path, 'output-${writes.length}.pdf'),
              ).writeAsString(jsonEncode(call.arguments));
              outputPaths.add(output.path);
              return output.path;
            }
            fail('Unexpected native call ${call.method}');
          },
        );
        addTearDown(() async {
          // Keep channel mocks installed until the widget's asynchronous PDF
          // disposal completes, including when an earlier assertion failed.
          await tester.pumpWidget(const SizedBox());
          final until = DateTime.now().add(const Duration(seconds: 5));
          while (nativeCalls.where((call) => call == 'close.document').length <
                  nativeCalls
                      .where((call) => call == 'open.document.file')
                      .length &&
              DateTime.now().isBefore(until)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          PdfxPlatform.instance = previousRenderer;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            inkChannel,
            null,
          );
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            rendererChannel,
            null,
          );
          debugDefaultTargetPlatformOverride = null;
          await tester.binding.setSurfaceSize(null);
          await db.close();
          await root.delete(recursive: true);
        });
        final doc = (await tester.runAsync(
          () => repository.fetchDocument('doc'),
        ))!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DocumentPreview(
                repository: repository,
                doc: doc.copyWith(type: 'doc'),
                onSave: (_) async {},
                onDelete: () {},
                onDownload: () {
                  downloaded = true;
                },
              ),
            ),
          ),
        );
        final annotator = find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_ImageAnnotator',
        );
        for (
          var attempt = 0;
          attempt < 200 && annotator.evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          renderCount,
          1,
          reason:
              '$nativeCalls / ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()}',
        );
        expect(annotator, findsOneWidget);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Pivoter le document de 90°'));
        await tester.pumpAndSettle();
        if (failAt == 'queue') {
          await tester.runAsync(
            () => db.execute("""
          CREATE TRIGGER reject_ink BEFORE INSERT ON sync_operations
          BEGIN SELECT RAISE(ABORT, 'synthetic full disk'); END
        """),
          );
        }
        Future<void> pressSave() async {
          final count = writes.length;
          await tester.runAsync(() async {
            await tester.tap(find.byTooltip('Enregistrer'));
          });
          await tester.pump();
          final saving = find.descendant(
            of: find.byTooltip('Enregistrer'),
            matching: find.byType(CircularProgressIndicator),
          );
          final until = DateTime.now().add(const Duration(seconds: 10));
          while ((writes.length == count || saving.evaluate().isNotEmpty) &&
              DateTime.now().isBefore(until)) {
            // File and SQLite work uses real I/O; fake frame time alone cannot
            // complete it. Wait for the actual save outcome, not a fixed delay.
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(writes.length, count + 1);
          expect(saving, findsNothing, reason: 'PDF save must finish');
          await tester.pumpAndSettle();
        }

        await pressSave();
        if (shouldFail) {
          await tester.runAsync(() async {
            expect(
              (await repository.fetchDocument('doc'))!.localPath,
              original.path,
            );
            expect(await db.query('sync_operations'), isEmpty);
            if (failAt == 'queue') await db.execute('DROP TRIGGER reject_ink');
          });
          expect(find.textContaining('Modifié'), findsOneWidget);
          expect(downloaded, isFalse);
          shouldFail = false;
          await pressSave();
        }
        final args = writes.last;
        expect(args['sourcePath'], original.path);
        expect(args['quarterTurns'], 1);
        final pages = args['pages'] as Map;
        expect(pages.keys, containsAll(['1', '2']));
        expect(pages['1'], hasLength(1));
        expect(pages['2'], hasLength(1));
        expect(pages['2'][0]['points'], pages['1'][0]['points']);
        expect(pages['2'][0]['widthFraction'], pages['1'][0]['widthFraction']);
        expect(pages['1'][0]['widthFraction'], greaterThan(0));
        await tester.runAsync(() async {
          final current = (await repository.fetchDocument('doc'))!;
          expect(current.localPath, isNot(original.path));
          expect(
            await File(current.localPath!).readAsString(),
            jsonEncode(args),
          );
          expect(await original.readAsString(), 'original PDF');
          expect(
            (await db.query('sync_operations')).single['status'],
            'pending',
          );
          for (final path in outputPaths) {
            expect(await File(path).exists(), isFalse);
          }
        });
        expect(find.textContaining('Modifié'), findsNothing);
        await tester.tap(find.byTooltip('Télécharger'));
        await tester.pumpAndSettle();
        expect(downloaded, isTrue);
        if (failAt == 'none') {
          Future<void> draw(Offset shift) async {
            final start = tester.getCenter(annotator) + shift;
            final gesture = await tester.startGesture(
              start,
              kind: PointerDeviceKind.stylus,
            );
            await gesture.moveTo(start + const Offset(25, 15));
            await gesture.up();
            await tester.pumpAndSettle();
          }

          await draw(Offset.zero);
          await pressSave();
          expect((writes.last['pages'] as Map)['1'], hasLength(2));
          expect((writes.last['pages'] as Map)['2'], hasLength(1));
          expect(find.textContaining('Modifié'), findsNothing);
          // Same number of points, different stroke: the old count-only
          // dirty hash incorrectly considered this already saved.
          await tester.tap(find.byTooltip('Annuler'));
          await tester.pumpAndSettle();
          await draw(const Offset(35, 25));
          expect(find.textContaining('Modifié'), findsOneWidget);
          await pressSave();
          expect((writes.last['pages'] as Map)['1'], hasLength(2));
          expect(writes.last['quarterTurns'], 1);
          expect(find.textContaining('Modifié'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
        PdfxPlatform.instance = previousRenderer;
      },
    );
  }
}
