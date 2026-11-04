import 'dart:async';
import 'package:aid_habitat_app/services/visit_report_preparation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'waits for the last browser edit after joining an earlier sync',
    () async {
      final activePush = Completer<void>();
      var pushes = 0;
      var remaining = 1;
      var generated = false;
      final preparation = waitForVisitReportSync(
        push: () async {
          pushes++;
          if (pushes == 1) {
            await activePush.future;
          } else {
            remaining = 0;
          }
        },
        pending: () async => remaining,
        conflicts: () async => 0,
        delay: (_) async {},
      ).then((_) => generated = true);
      await Future<void>.delayed(Duration.zero);
      expect(generated, isFalse);
      activePush.complete();
      await preparation;
      expect(pushes, 2);
      expect(generated, isTrue);
    },
  );

  test(
    'blocks a report on a conflict or an unacknowledged photo order',
    () async {
      for (final conflict in [false, true]) {
        await expectLater(
          waitForVisitReportSync(
            push: () async {},
            pending: () async => 1,
            conflicts: () async => conflict ? 1 : 0,
            timeout: Duration.zero,
          ),
          conflict ? throwsStateError : throwsA(isA<TimeoutException>()),
        );
      }
    },
  );

  test(
    'flush waits for a mounted editor and propagates its save failure',
    () async {
      final owner = Object();
      final save = Completer<void>();
      VisitReportEdits.register(owner, () => 'patient', () => save.future);
      addTearDown(() => VisitReportEdits.unregister(owner));
      await VisitReportEdits.flush('other-patient');
      final result = VisitReportEdits.flush('patient');
      final expectation = expectLater(result, throwsStateError);
      save.completeError(StateError('Unable to save photo order'));
      await expectation;
    },
  );
}
