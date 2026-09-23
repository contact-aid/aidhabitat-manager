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
}
