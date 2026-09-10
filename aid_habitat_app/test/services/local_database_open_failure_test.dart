import 'dart:io';

import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final error in [
    StateError('migration failed'),
    const FileSystemException('disk full'),
    StateError('file is not a database'),
  ]) {
    test('opening failure retains the database and sidecars: $error', () async {
      final directory = await Directory.systemTemp.createTemp(
        'database-preservation-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/offline.db';
      final files = <String, List<int>>{};
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final bytes = List.generate(128, (i) => (i + suffix.length) % 256);
        files['$path$suffix'] = bytes;
        await File('$path$suffix').writeAsBytes(bytes);
      }
      var attempts = 0;
      await expectLater(
        LocalDatabase.instance.openEncryptedForTesting(
          path,
          readKey: () async => 'synthetic key',
          opener: (target, key) async {
            attempts++;
            expect(target, path);
            expect(key, 'synthetic key');
            throw error;
          },
        ),
        throwsA(same(error)),
      );
      expect(attempts, 1);
      expect(await directory.list().length, files.length);
      for (final entry in files.entries) {
        expect(await File(entry.key).readAsBytes(), entry.value);
      }
    });
  }

  test(
    'key access failure does not attempt opening or reset the database',
    () async {
      final error = StateError('keychain unavailable');
      await expectLater(
        LocalDatabase.instance.openEncryptedForTesting(
          '/unused',
          readKey: () async => throw error,
          opener: (_, _) async => fail('Must not open without the key'),
        ),
        throwsA(same(error)),
      );
    },
  );
}
