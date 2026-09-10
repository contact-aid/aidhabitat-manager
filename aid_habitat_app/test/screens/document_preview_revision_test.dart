import 'dart:io';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/documents_screen.dart';
import 'package:aid_habitat_app/services/document_repository.dart';
import 'package:aid_habitat_app/services/document_revision_store.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('image rotation refuses a revision received after opening', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    late Directory root;
    late Database db;
    late DocumentRepository repository;
    late DocItem opened;
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 20, height: 10)),
    );
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('image-preview-revision-');
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final source = await File(
        p.join(root.path, 'source.png'),
      ).writeAsBytes(bytes);
      await db.insert('documents', {
        'local_id': 'doc',
        'patient_local_id': 'patient',
        'title': 'Photo',
        'file_name': 'photo.png',
        'file_ext': 'png',
        'mime_type': 'image/png',
        'local_file_path': source.path,
        'tags_json': '[]',
        'created_at': '2026-09-10T10:00:00Z',
        'updated_at': '2026-09-10T10:00:00Z',
        'sync_state': 'synced',
      });
      repository = DocumentRepository(
        database: local,
        revisionStore: DocumentRevisionStore(
          documentsDirectory: () async => root,
        ),
      );
      opened = (await repository.fetchDocument('doc'))!;
    });
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentPreview(
            repository: repository,
            doc: opened,
            onSave: (_) async {},
            onDelete: () {},
            onDownload: () {},
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
    late String receivedPath;
    await tester.runAsync(() async {
      final received = await repository.enqueueReplacementBytes(
        documentId: 'doc',
        bytes: bytes,
        fileName: 'photo.png',
        mimeType: 'image/png',
      );
      receivedPath = received.localPath!;
    });
    await tester.tap(find.byTooltip('Pivoter le document de 90°'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Enregistrer'));
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find
            .textContaining('Enregistrement impossible')
            .evaluate()
            .isNotEmpty) {
          return;
        }
      }
      fail('Stale image save was not rejected');
    });
    expect(find.textContaining('Modifié'), findsWidgets);
    await tester.runAsync(() async {
      expect((await repository.fetchDocument('doc'))!.localPath, receivedPath);
      expect(await db.query('sync_operations'), hasLength(1));
    });
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'successive PDF saves use the opening revision and restore a full turn',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      late Directory root;
      late Database db;
      late File original;
      late DocumentRepository repository;
      const now = '2026-09-09T10:00:00.000Z';
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('preview-revision-');
        db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        final local = LocalDatabase.forTesting(db);
        await local.createSchemaForTesting();
        original = await File(
          p.join(root.path, 'source.pdf'),
        ).writeAsString('opening-pdf');
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
      final calls = <MethodCall>[];
      final outputs = <String>[];
      const channel = MethodChannel('aidhabitat/pdf_rotation');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        expect(call.arguments['sourcePath'], original.path);
        expect(original.readAsStringSync(), 'opening-pdf');
        final output = await File(
          p.join(root.path, 'rotated-${calls.length}.pdf'),
        ).writeAsString('rotation-${call.arguments['quarterTurns']}');
        outputs.add(output.path);
        return output.path;
      });
      addTearDown(() async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        debugDefaultTargetPlatformOverride = null;
        await tester.binding.setSurfaceSize(null);
        await db.close();
        await root.delete(recursive: true);
      });

      // The renderer is not under test: PDFKit is simulated, SQLite and files
      // are real. A generic type avoids the redundant PDF controller in init.
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentPreview(
            repository: repository,
            doc: DocItem(
              id: 'doc',
              type: 'doc',
              name: 'devis sdb.pdf',
              title: 'Devis',
              date: now,
              localPath: original.path,
            ),
            onSave: (_) async {},
            onDelete: () {},
            onDownload: () {},
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      var previousPath = original.path;
      for (var turn = 1; turn <= 4; turn++) {
        await tester.tap(find.byTooltip('Pivoter le document de 90°'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('Enregistrer'));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (DateTime.now().isBefore(deadline)) {
            final current = await repository.fetchDocument('doc');
            if (current!.localPath != previousPath) {
              previousPath = current.localPath!;
              expect(
                await File(previousPath).readAsString(),
                turn == 4 ? 'opening-pdf' : 'rotation-$turn',
              );
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          fail('rotation save did not commit');
        });
        await tester.pumpAndSettle();
        expect(find.textContaining('Modifié'), findsNothing);
        expect(original.readAsStringSync(), 'opening-pdf');
      }
      expect(calls.map((call) => call.arguments['quarterTurns']), [1, 2, 3]);
      for (final output in outputs) {
        expect(File(output).existsSync(), isFalse);
      }
      await tester.runAsync(() async {
        expect(await db.query('sync_operations'), hasLength(1));
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
