import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/services/visit_date_time.dart';

void main() {
  group('serializeVisitDateTime', () {
    test('French summer time survives a server UTC round trip', () {
      final encoded = serializeVisitDateTime(DateTime(2026, 9, 10, 14, 30));
      expect(encoded, '2026-09-10T12:30:00.000Z');
      final displayed = parseVisitDateTime(encoded)!;
      expect(displayed.hour, 14);
      expect(displayed.minute, 30);
    });
    test('winter uses the French winter offset, not the device offset', () {
      expect(
        serializeVisitDateTime(DateTime.utc(2026, 12, 10, 14, 30)),
        '2026-12-10T13:30:00.000Z',
      );
    });
    test(
      'nonexistent spring clock time is rejected instead of silently shifted',
      () {
        expect(
          () => serializeVisitDateTime(DateTime.utc(2026, 3, 29, 2, 30)),
          throwsFormatException,
        );
      },
    );
  });
  group('parseVisitDateTime', () {
    test('converts UTC timestamps to Europe/Paris in summer', () {
      const raw = '2026-08-04T08:00:00.000Z';
      final parsed = parseVisitDateTime(raw);

      expect(parsed, isNotNull);
      expect(parsed!.hour, 10);
      expect(parsed.minute, 0);
      expect(parsed.timeZoneOffset, const Duration(hours: 2));
      expect(parsed.toUtc(), DateTime.utc(2026, 8, 4, 8));
    });

    test('applies the Europe/Paris winter offset', () {
      final parsed = parseVisitDateTime('2026-12-04T08:00:00.000Z');

      expect(parsed, isNotNull);
      expect(parsed!.hour, 9);
      expect(parsed.timeZoneOffset, const Duration(hours: 1));
    });

    test('keeps local timestamps unchanged', () {
      expect(
        parseVisitDateTime('2026-07-28T10:00:00'),
        DateTime(2026, 7, 28, 10),
      );
    });

    test('keeps date-only values on their calendar day', () {
      expect(parseVisitDateTime('2026-07-28'), DateTime(2026, 7, 28));
    });

    test('returns null for empty or invalid values', () {
      expect(parseVisitDateTime(null), isNull);
      expect(parseVisitDateTime(''), isNull);
      expect(parseVisitDateTime('not-a-date'), isNull);
    });
  });
}
