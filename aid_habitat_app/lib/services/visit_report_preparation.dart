import 'dart:async';

/// Mounted editors must finish their durable local writes before a report
/// checks the queue. A visible drag preview or debounce is not a saved edit.
class VisitReportEdits {
  static final _editors =
      <
        Object,
        ({String Function() patientId, Future<void> Function() flush})
      >{};

  static void register(
    Object owner,
    String Function() patientId,
    Future<void> Function() flush,
  ) {
    _editors[owner] = (patientId: patientId, flush: flush);
  }

  static void unregister(Object owner) => _editors.remove(owner);

  static Future<void> flush(String patientId) async {
    for (final editor in List.of(_editors.values)) {
      if (editor.patientId() == patientId) await editor.flush();
    }
  }
}

/// A running background push may have captured its queue before the last edit.
/// Join it, then drain again until this report has no unacknowledged writes.
Future<void> waitForVisitReportSync({
  required Future<void> Function() push,
  required Future<int> Function() pending,
  required Future<int> Function() conflicts,
  Duration timeout = const Duration(seconds: 45),
  Future<void> Function(Duration)? delay,
}) async {
  final clock = Stopwatch()..start();
  final pause = delay ?? (duration) => Future<void>.delayed(duration);
  do {
    await push();
    if (await conflicts() > 0) {
      throw StateError(
        'Des conflits doivent être résolus avant de générer le rapport.',
      );
    }
    if (await pending() == 0) return;
    if (clock.elapsed >= timeout) break;
    await pause(const Duration(milliseconds: 500));
  } while (clock.elapsed < timeout);
  throw TimeoutException(
    'Les modifications ne sont pas encore toutes enregistrées sur le serveur. Le rapport reste en attente.',
  );
}
