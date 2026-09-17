import 'types.dart';

/// Calendar dates only: invalid dates must not roll into an eligible birthday.
int? beneficiaryAge(String value, {DateTime? today}) {
  final raw = value.trim();
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:T.*)?$').firstMatch(raw);
  final french = RegExp(r'^(\d{2})[/.-](\d{2})[/.-](\d{4})$').firstMatch(raw);
  if (iso == null && french == null) return null;
  final year = int.parse(iso?.group(1) ?? french!.group(3)!);
  final month = int.parse(iso?.group(2) ?? french!.group(2)!);
  final day = int.parse(iso?.group(3) ?? french!.group(1)!);
  final birth = DateTime(year, month, day);
  final now = today ?? DateTime.now();
  if (year < 1900 ||
      birth.year != year ||
      birth.month != month ||
      birth.day != day ||
      birth.isAfter(DateTime(now.year, now.month, now.day))) {
    return null;
  }
  return now.year -
      year -
      (now.month < month || (now.month == month && now.day < day) ? 1 : 0);
}

bool requiresAggir(String birthDate, {DateTime? today}) {
  final age = beneficiaryAge(birthDate, today: today);
  return age != null && age >= 60 && age <= 69;
}

bool primaryBeneficiaryRequiresAggir(Patient patient, {DateTime? today}) =>
    requiresAggir(
      patient.occupants.isEmpty
          ? patient.birthDate
          : patient.occupants.first.birthDate,
      today: today,
    );
