// Picked only by the web target through the conditional import.
import 'dart:js_interop';

@JS('aidHabitatPrepareSpeechRecognition')
external JSPromise<JSString> _prepareSpeechRecognition(JSString locale);

Future<String> prepareWebVoiceSpeechRuntimeImpl() async {
  try {
    final result = await _prepareSpeechRecognition('fr-FR'.toJS).toDart;
    return result.toDart;
  } catch (_) {
    return 'remote';
  }
}

@JS('aidHabitatStartSpeechRecognition')
external void _start(JSFunction result, JSFunction status, JSFunction error);
@JS('aidHabitatStopSpeechRecognition')
external void _stop();
@JS('aidHabitatCancelSpeechRecognition')
external void _cancel();

void startWebVoiceRecognition({
  required void Function(String) onResult,
  required void Function(String) onStatus,
  required void Function(String) onError,
}) {
  _start(
    ((JSString value) => onResult(value.toDart)).toJS,
    ((JSString value) => onStatus(value.toDart)).toJS,
    ((JSString value) => onError(value.toDart)).toJS,
  );
}

void stopWebVoiceRecognition() => _stop();
void cancelWebVoiceRecognition() => _cancel();
