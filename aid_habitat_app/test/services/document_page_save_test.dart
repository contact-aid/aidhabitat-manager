import 'package:aid_habitat_app/services/document_page_save.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'partial failure retains failed and unattempted pages for retry',
    () async {
      final dirty = {1, 2, 3};
      final attempts = <int>[];
      final failure = StateError('storage unavailable');

      await expectLater(
        persistDirtyDocumentPages(
          dirtyPages: dirty,
          persistPage: (page) async {
            attempts.add(page);
            if (page == 2) throw failure;
          },
        ),
        throwsA(same(failure)),
      );
      expect(attempts, [1, 2]);
      expect(dirty, {2, 3});

      await persistDirtyDocumentPages(
        dirtyPages: dirty,
        persistPage: (page) async => attempts.add(page),
      );
      expect(attempts, [1, 2, 2, 3]);
      expect(dirty, isEmpty);
    },
  );

  test('failure on the first page leaves every page pending', () async {
    final dirty = {2, 4};
    await expectLater(
      persistDirtyDocumentPages(
        dirtyPages: dirty,
        persistPage: (_) async => throw StateError('disk full'),
      ),
      throwsStateError,
    );
    expect(dirty, {2, 4});
  });

  test(
    'successful save acknowledges each page and a second save is a no-op',
    () async {
      final dirty = {1, 3};
      final attempts = <int>[];
      for (var i = 0; i < 2; i++) {
        await persistDirtyDocumentPages(
          dirtyPages: dirty,
          persistPage: (page) async => attempts.add(page),
        );
      }
      expect(attempts, [1, 3]);
      expect(dirty, isEmpty);
    },
  );
}
