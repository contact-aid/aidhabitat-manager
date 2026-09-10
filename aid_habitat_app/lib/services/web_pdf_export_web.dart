// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

html.Worker? _worker;
Future<void>? _ready;
StreamSubscription? _messages;
StreamSubscription? _errors;
final _pending = <int, Completer<Uint8List>>{};
int _nextId = 0;

void _reset(Object error) {
  _worker?.terminate();
  _worker = null;
  _ready = null;
  _messages?.cancel();
  _errors?.cancel();
  for (final request in _pending.values) {
    if (!request.isCompleted) request.completeError(error);
  }
  _pending.clear();
}

Future<void> prepareWebPdfExport() {
  if (_ready != null) return _ready!;
  final ready = Completer<void>();
  try {
    _worker = html.Worker(
      Uri.parse(
        html.document.baseUri!,
      ).resolve('pdf-export/pdf-export-worker.js').toString(),
    );
    _messages = _worker!.onMessage.listen((event) {
      final data = event.data as Map;
      if (data['ready'] == true) {
        if (!ready.isCompleted) ready.complete();
        return;
      }
      final request = _pending.remove(data['id']);
      if (request == null) return;
      if (data['error'] != null) {
        request.completeError(StateError(data['error'].toString()));
      } else if (data['bytes'] is Uint8List) {
        request.complete(data['bytes'] as Uint8List);
      } else {
        request.completeError(StateError('PDF produit invalide'));
      }
    });
    _errors = _worker!.onError.listen((_) {
      final error = StateError(
        'Moteur PDF indisponible. Modifications conservees.',
      );
      if (!ready.isCompleted) ready.completeError(error);
      _reset(error);
    });
  } catch (error) {
    ready.completeError(error);
  }
  return _ready = ready.future.timeout(const Duration(seconds: 20)).catchError((
    Object error,
  ) {
    _reset(error);
    throw error;
  });
}

Future<Uint8List> exportWebPdfImpl(
  Uint8List source,
  Map<String, Object> pages,
  int quarterTurns,
) async {
  await prepareWebPdfExport();
  final id = ++_nextId;
  final result = Completer<Uint8List>();
  _pending[id] = result;
  try {
    // Clone input buffers: the open viewer must retain its original bytes.
    _worker!.postMessage({
      'id': id,
      'source': source,
      'pages': pages,
      'quarterTurns': quarterTurns,
    });
    return await result.future.timeout(const Duration(minutes: 2));
  } on TimeoutException catch (error) {
    _pending.remove(id);
    _reset(error);
    rethrow;
  } finally {
    _pending.remove(id);
  }
}
