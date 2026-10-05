import 'dart:math' as math;

import 'types.dart';

/// Presentation only: never pass these inferred rows to a repository save.
/// Stored identities and medical information are never changed by this helper.
List<Occupant> dossierOccupants(Patient patient) {
  final hasSecond =
      patient.secondFirstName.trim().isNotEmpty ||
      patient.secondLastName.trim().isNotEmpty;
  final count = math.max(
    math.max(patient.numberPeople ?? 1, patient.occupants.length),
    hasSecond ? 2 : 1,
  );
  final occupants = List<Occupant>.generate(count, (index) {
    var occupant = index < patient.occupants.length
        ? patient.occupants[index]
        : index == 0
        ? Occupant(
            birthDate: patient.birthDate,
            apa: patient.apa,
            invalidity: patient.invalidity,
            invalidityTxt: patient.invalidityTxt,
            homeHelp: patient.homeHelp,
            homeHelpTxt: patient.homeHelpTxt,
            dependenceTxt: patient.dependenceTxt,
            caisseRetraitePrincipale: patient.caisseRetraitePrincipale,
            caissesRetraiteComplementaires:
                patient.caissesRetraiteComplementaires,
          )
        : const Occupant();
    if (index == 0 &&
        occupant.firstName.trim().isEmpty &&
        occupant.lastName.trim().isEmpty) {
      occupant = occupant.copyWith(
        firstName: patient.firstName,
        lastName: patient.lastName,
      );
    } else if (index == 1 &&
        hasSecond &&
        occupant.firstName.trim().isEmpty &&
        occupant.lastName.trim().isEmpty) {
      occupant = occupant.copyWith(
        firstName: patient.secondFirstName,
        lastName: patient.secondLastName,
      );
    }
    return occupant;
  });

  final primaryMatchesLegacy =
      _normalizedName(occupants.first.firstName) ==
          _normalizedName(patient.firstName) &&
      _normalizedName(occupants.first.lastName) ==
          _normalizedName(patient.lastName);
  if (!primaryMatchesLegacy) return occupants;

  // Some imports put two complete names in the legacy Nom / Prénom fields,
  // e.g. "LECUYER Daniel" / "LECUYER Heike". Only split a repeated uppercase
  // surname followed by distinct simple given names, with an empty second row.
  final fullNames = _sharedSurnameIdentities(
    patient.lastName,
    patient.firstName,
  );
  if (occupants.length == 2 &&
      fullNames != null &&
      occupants[1].firstName.trim().isEmpty &&
      (occupants[1].lastName.trim().isEmpty ||
          _normalizedName(occupants[1].lastName) ==
              _normalizedName(fullNames.lastName))) {
    occupants[0] = occupants[0].copyWith(
      firstName: fullNames.firstName,
      lastName: fullNames.lastName,
    );
    occupants[1] = occupants[1].copyWith(
      firstName: fullNames.secondFirstName,
      lastName: fullNames.lastName,
    );
    return occupants;
  }

  // Only two simple given names joined by “et”/“&”, in a declared household
  // of at least two people, with no conflicting second identity.
  final jointNames = RegExp(
    r"^([A-Za-zÀ-ÖØ-öø-ÿŒœ]+(?:[-’'][A-Za-zÀ-ÖØ-öø-ÿŒœ]+)*)\s+(?:et|&)\s+([A-Za-zÀ-ÖØ-öø-ÿŒœ]+(?:[-’'][A-Za-zÀ-ÖØ-öø-ÿŒœ]+)*)$",
    caseSensitive: false,
  ).firstMatch(patient.firstName.trim());
  if (occupants.length == 2 &&
      patient.lastName.trim().isNotEmpty &&
      !RegExp(
        r'\s+(?:et|&)\s+',
        caseSensitive: false,
      ).hasMatch(patient.lastName) &&
      jointNames != null &&
      _normalizedName(jointNames.group(1)!) !=
          _normalizedName(jointNames.group(2)!) &&
      occupants[1].firstName.trim().isEmpty &&
      (occupants[1].lastName.trim().isEmpty ||
          occupants[1].lastName.trim() == patient.lastName.trim())) {
    occupants[0] = occupants[0].copyWith(firstName: jointNames.group(1));
    occupants[1] = occupants[1].copyWith(
      firstName: jointNames.group(2),
      lastName: patient.lastName,
    );
  }
  return occupants;
}

String _normalizedName(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

({String lastName, String firstName, String secondFirstName})?
_sharedSurnameIdentities(String left, String right) {
  final leftParts = left.trim().split(RegExp(r'\s+'));
  final rightParts = right.trim().split(RegExp(r'\s+'));
  var common = 0;
  while (common < leftParts.length - 1 &&
      common < rightParts.length - 1 &&
      leftParts[common] == rightParts[common] &&
      leftParts[common] == leftParts[common].toUpperCase()) {
    common++;
  }
  if (common == 0) return null;
  final lastName = leftParts.take(common).join(' ');
  final firstName = leftParts.skip(common).join(' ');
  final secondFirstName = rightParts.skip(common).join(' ');
  final simpleName = RegExp(
    r"^[A-Za-zÀ-ÖØ-öø-ÿŒœ]+(?:[-’'][A-Za-zÀ-ÖØ-öø-ÿŒœ]+)*$",
  );
  if (!lastName.split(' ').every(simpleName.hasMatch) ||
      !simpleName.hasMatch(firstName) ||
      !simpleName.hasMatch(secondFirstName) ||
      _normalizedName(firstName) == _normalizedName(secondFirstName) ||
      (firstName == firstName.toUpperCase() &&
          secondFirstName == secondFirstName.toUpperCase())) {
    return null;
  }
  return (
    lastName: lastName,
    firstName: firstName,
    secondFirstName: secondFirstName,
  );
}

/// Formats uppercase imports for display only; stored spelling stays intact.
String _displayName(String value) {
  final trimmed = value.trim();
  if (trimmed != trimmed.toUpperCase()) return trimmed;
  return trimmed.toLowerCase().replaceAllMapped(
    RegExp(r"(^|[\s’'-])([a-zà-öø-ÿœ])"),
    (match) => '${match[1]}${match[2]!.toUpperCase()}',
  );
}

String dossierBeneficiaryTitle(Patient patient, {List<Occupant>? occupants}) {
  final named = (occupants ?? dossierOccupants(patient))
      .where(
        (occupant) =>
            occupant.firstName.trim().isNotEmpty ||
            occupant.lastName.trim().isNotEmpty,
      )
      .toList();
  if (named.length <= 1) {
    final primary = named.isEmpty ? null : named.first;
    return '${(primary?.lastName ?? patient.lastName).trim().toUpperCase()} '
            '${(primary?.firstName ?? patient.firstName).trim()}'
        .trim();
  }
  final surname = named.first.lastName;
  if (surname.trim().isNotEmpty &&
      named.every(
        (occupant) =>
            occupant.firstName.trim().isNotEmpty &&
            _normalizedName(occupant.lastName) == _normalizedName(surname),
      )) {
    return '${named.map((o) => _displayName(o.firstName)).join(' et ')} '
        '${_displayName(surname)}';
  }
  return named
      .map(
        (o) => [
          _displayName(o.firstName),
          _displayName(o.lastName),
        ].where((value) => value.isNotEmpty).join(' '),
      )
      .join(' et ');
}

/// Exposes unresolved grouped names and disagreements without guessing a person.
bool dossierIdentityNeedsReview(Patient patient) {
  final rows = dossierOccupants(patient);
  final original = '${patient.lastName} ${patient.firstName}';
  final grouped =
      RegExp(r'\s+(?:et|&)\s+', caseSensitive: false).hasMatch(original) ||
      _sharedSurnameIdentities(patient.lastName, patient.firstName) != null;
  final split =
      rows.length == 2 &&
      rows[0].firstName != patient.firstName &&
      patient.occupants.every(
        (o) => o.firstName.isEmpty || o.firstName == patient.firstName,
      );
  final conflicts =
      patient.occupants.isNotEmpty &&
      (patient.occupants.first.firstName.isNotEmpty ||
          patient.occupants.first.lastName.isNotEmpty) &&
      (_normalizedName(patient.occupants.first.firstName) !=
              _normalizedName(patient.firstName) ||
          _normalizedName(patient.occupants.first.lastName) !=
              _normalizedName(patient.lastName));
  return conflicts || (grouped && !split);
}

String dossierOccupantDisplayName(Occupant occupant, int index) {
  final civility = switch (occupant.gender) {
    'Homme' => 'M.',
    'Femme' => 'Mme.',
    _ => '',
  };
  final name = [
    civility,
    occupant.lastName.trim().toUpperCase(),
    occupant.firstName.trim(),
  ].where((value) => value.isNotEmpty).join(' ');
  final maiden = occupant.maidenName?.trim() ?? '';
  return '${name.isEmpty ? 'Occupant ${index + 1}' : name}'
      '${maiden.isEmpty ? '' : ' (nom de naissance : $maiden)'}';
}
