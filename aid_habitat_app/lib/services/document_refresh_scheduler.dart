import 'dart:async';

/// Reads incoming documents while their screen is visible. Uploads and local
/// edits keep their own queues; a slow read never starts a second polling read.
class DocumentRefreshScheduler {
  DocumentRefreshScheduler({
    required this.refresh,
    this.interval = const Duration(seconds: 15),
  });

  final Future<void> Function() refresh;
  final Duration interval;
  Timer? _timer;
  bool _reading = false;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(_read()));
  }

  Future<void> _read() async {
    if (_reading || _timer == null) return;
    _reading = true;
    try {
      await refresh();
    } catch (_) {
      // Keep the current local snapshot and retry on the next tick.
    } finally {
      _reading = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
