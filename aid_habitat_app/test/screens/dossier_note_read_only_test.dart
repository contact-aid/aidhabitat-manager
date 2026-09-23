import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opening a dossier refreshes the quick note without writing it', () {
    final source = File('lib/screens/dossier_screen.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _refreshQuickNoteFromRemote()');
    final end = source.indexOf('\n  List<CommuneOption>', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final openingFlow = source.substring(start, end);
    expect(openingFlow, contains('refreshNotePageFromRemote'));
    expect(openingFlow, isNot(contains('saveNoteDrawingJson')));
    expect(openingFlow, isNot(contains('refreshObservationsFromRemote')));
  });

  test('page navigation hydrates note text without firing its listener', () {
    final source = File('lib/components/notes_widget.dart').readAsStringSync();
    final start = source.indexOf('void _switchPage(int page)');
    final end = source.indexOf('\n  /// Pousse les flags', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final pageSwitch = source.substring(start, end);
    expect(pageSwitch, contains('_setControllerSilently'));
    expect(pageSwitch, isNot(contains('_textController.text =')));
    expect(pageSwitch, isNot(contains('_saveNoteDrawingJson')));
  });

  test('remote medical flag hydration cannot be mistaken for user input', () {
    final source = File('lib/components/notes_widget.dart').readAsStringSync();
    final start = source.indexOf(
      'if (!medicalScopeChanged &&',
      source.indexOf('void didUpdateWidget'),
    );
    final end = source.indexOf('\n    if (oldWidget.totalPages', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final flagUpdate = source.substring(start, end);
    expect(flagUpdate, contains('medicalFlagsUserEditRevision'));
    expect(flagUpdate, contains('_persistPage'));
  });
}
