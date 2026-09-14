import 'dart:io';
import 'package:aid_habitat_app/services/document_storage_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'container move recovers exact revision without modifying stored path',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'relocated-documents-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File(
        '${root.path}/document_revisions/revision_A/content.pdf',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('synthetic-pdf');
      const old =
          '/missing/container/OLD/Documents/document_revisions/revision_A/content.pdf';
      expect(
        await resolveDocumentStoragePath(
          old,
          documentsDirectory: () async => root,
        ),
        file.path,
      );
      const other =
          '/missing/container/OLD/Documents/document_revisions/revision_B/content.pdf';
      expect(
        await resolveDocumentStoragePath(
          other,
          documentsDirectory: () async => root,
        ),
        other,
      );
      expect(await file.readAsString(), 'synthetic-pdf');
    },
  );
  test('reject traversal, unrelated caches and basename-only recovery', () {
    expect(
      documentStorageKey('/old/Documents/document_revisions/../content.pdf'),
      isNull,
    );
    expect(documentStorageKey('/old/Library/Caches/content.pdf'), isNull);
    expect(documentStorageKey('content.pdf'), isNull);
  });
}
