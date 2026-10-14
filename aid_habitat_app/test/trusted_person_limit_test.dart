import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/components/form_widgets.dart';

void main() {
  testWidgets(
    'counter blocks an over-limit edit and preserves existing longer values',
    (tester) async {
      String? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormTextField(
              label: 'Personne de confiance',
              maxLength: 100,
              value: 'Initial',
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      );
      final field = find.byType(TextFormField);
      await tester.enterText(field, 'A' * 100);
      await tester.pump();
      expect(changed, 'A' * 100);
      expect(find.text('100/100'), findsOneWidget);
      await tester.enterText(field, 'A' * 101);
      expect(changed, 'A' * 100);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormTextField(
              key: const ValueKey('legacy'),
              label: 'Personne de confiance',
              maxLength: 100,
              value: 'B' * 120,
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      );
      expect(find.text('B' * 120), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'B' * 110);
      expect(changed, 'B' * 110);
    },
  );
}
