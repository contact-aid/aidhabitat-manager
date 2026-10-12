import 'dart:convert';
import 'dart:js_interop';

@JS('aidHabitatLocalAiStatus')
external JSPromise<JSString> _status();
@JS('aidHabitatLocalAiPrepare')
external JSPromise<JSString> _prepare();
@JS('aidHabitatLocalAiRewrite')
external JSPromise<JSString> _rewrite(
  JSString text,
  JSString mode,
  JSString context,
);
@JS('aidHabitatLocalAiProgress')
external JSNumber _progress();
@JS('aidHabitatLocalAiPhase')
external JSString _phase();
@JS('aidHabitatLocalAiLastError')
external JSString _lastError();
@JS('aidHabitatLocalAiCancel')
external void _cancel();

Future<Map<String, dynamic>> localAiStatus() async {
  try {
    return jsonDecode((await _status().toDart).toDart) as Map<String, dynamic>;
  } catch (_) {
    return {'supported': false};
  }
}

Future<void> prepareLocalAi() async {
  try {
    await _prepare().toDart;
  } catch (_) {
    final message = _lastError().toDart;
    throw Exception(
      message.isNotEmpty
          ? message
          : 'Préparation locale impossible. Vérifiez la connexion et le stockage libre.',
    );
  }
}

Future<String> rewriteLocalAi(String text, String mode, String context) async {
  try {
    return (await _rewrite(text.toJS, mode.toJS, context.toJS).toDart).toDart;
  } catch (_) {
    throw Exception(
      'Reformulation locale impossible. La note originale est conservee. Verifiez le modele local ou raccourcissez la note.',
    );
  }
}

double localAiProgress() => _progress().toDartDouble;
void cancelLocalAi() => _cancel();

String localAiPhase() => _phase().toDart;
