import 'dart:convert';
import 'dart:js_interop';

@JS('aidHabitatLocalAiStatus')
external JSPromise<JSString> _status();
@JS('aidHabitatLocalAiPrepare')
external JSPromise<JSString> _prepare();
@JS('aidHabitatLocalAiRewrite')
external JSPromise<JSString> _rewrite(JSString text, JSString mode);
@JS('aidHabitatLocalAiProgress')
external JSNumber _progress();
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
    throw Exception(
      'Preparation locale impossible. Verifiez la connexion et au moins 1,3 Go de stockage libre.',
    );
  }
}

Future<String> rewriteLocalAi(String text, String mode) async {
  try {
    return (await _rewrite(text.toJS, mode.toJS).toDart).toDart;
  } catch (_) {
    throw Exception(
      'Reformulation locale impossible. La note originale est conservee. Verifiez le modele local ou raccourcissez la note.',
    );
  }
}

double localAiProgress() => _progress().toDartDouble;
void cancelLocalAi() => _cancel();
