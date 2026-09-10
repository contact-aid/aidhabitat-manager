import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

final tz.Location _parisLocation = () {
  tz_data.initializeTimeZones();
  return tz.getLocation('Europe/Paris');
}();

/// Picker values are French wall time, irrespective of the device timezone.
/// Send an explicit instant so NocoDB cannot reinterpret it as UTC wall time.
/// Use DateTime.utc as a wall-time carrier to avoid device DST normalization.
String serializeVisitDateTime(DateTime wallTime) {
  final paris = tz.TZDateTime(
    _parisLocation,
    wallTime.year,
    wallTime.month,
    wallTime.day,
    wallTime.hour,
    wallTime.minute,
    wallTime.second,
  );
  if (paris.year != wallTime.year ||
      paris.month != wallTime.month ||
      paris.day != wallTime.day ||
      paris.hour != wallTime.hour ||
      paris.minute != wallTime.minute) {
    throw const FormatException('Heure de visite inexistante en Europe/Paris');
  }
  return paris.toUtc().toIso8601String();
}

DateTime? parseVisitDateTime(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;

  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;

  // A date-only value represents a local calendar day, even if a legacy
  // source appended a timezone marker.
  final hasTime = RegExp(r'[T ]\d{2}:\d{2}').hasMatch(value);
  if (!hasTime) {
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  // Les visites sont planifiées en France. Une conversion avec `toLocal()`
  // dépendrait du fuseau configuré sur chaque iPad et pourrait donc afficher
  // une heure différente d'un appareil à l'autre.
  return parsed.isUtc ? tz.TZDateTime.from(parsed, _parisLocation) : parsed;
}
