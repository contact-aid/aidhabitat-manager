import 'dart:async';

import 'package:aid_habitat_app/services/document_refresh_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'visible screen reads repeatedly and pauses without overlapping reads',
    (tester) async {
      var reads = 0;
      final pending = Completer<void>();
      final scheduler = DocumentRefreshScheduler(
        refresh: () {
          reads++;
          return reads == 1 ? pending.future : Future.value();
        },
      );
      scheduler.start();
      scheduler.start();
      await tester.pump(const Duration(seconds: 15));
      expect(reads, 1);
      await tester.pump(const Duration(seconds: 45));
      expect(reads, 1);
      pending.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 15));
      expect(reads, 2);
      scheduler.stop();
      await tester.pump(const Duration(minutes: 1));
      expect(reads, 2);
      scheduler.start();
      await tester.pump(const Duration(seconds: 15));
      expect(reads, 3);
      scheduler.stop();
    },
  );

  testWidgets('failed incoming read does not stop subsequent refreshes', (
    tester,
  ) async {
    var reads = 0;
    final scheduler = DocumentRefreshScheduler(
      refresh: () async {
        if (++reads == 1) throw StateError('network unavailable');
      },
    );
    scheduler.start();
    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 15));
    expect(reads, 2);
    scheduler.stop();
  });
}
