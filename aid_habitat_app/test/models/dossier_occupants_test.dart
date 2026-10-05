import 'package:aid_habitat_app/models/dossier_occupants.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter_test/flutter_test.dart';

Patient patient({
  String firstName = 'René et Madeleine',
  String lastName = 'Exemple',
  int count = 2,
  List<Occupant> occupants = const [],
  String secondName = '',
}) => Patient(
  id: 'synthetic',
  firstName: firstName,
  lastName: lastName,
  birthDate: '1948-04-12',
  phone: '',
  email: '',
  address: '',
  city: '',
  zipCode: '',
  familySituation: '',
  incomeCategory: '',
  numberPeople: count,
  occupants: occupants,
  secondFirstName: secondName,
  apa: true,
  homeHelpTxt: 'Aide conservée',
  trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
);

void main() {
  test('structured conflicting identities remain intact and are flagged', () {
    final original = patient(
      firstName: 'Ancien',
      occupants: const [
        Occupant(
          firstName: 'Camille',
          lastName: 'Actuel',
          maidenName: 'Naissance',
        ),
        Occupant(firstName: 'Alex', lastName: 'Actuel'),
      ],
    );
    final rows = dossierOccupants(original);
    expect(rows.first.firstName, 'Camille');
    expect(dossierIdentityNeedsReview(original), isTrue);
    expect(
      dossierOccupantDisplayName(rows.first, 0),
      'ACTUEL Camille (nom de naissance : Naissance)',
    );
  });
  test('uncertain joint identities are flagged and not guessed', () {
    for (final original in [
      patient(firstName: 'Marie Claire et Jean'),
      patient(count: 1),
      patient(count: 3),
      patient(lastName: ''),
    ]) {
      expect(dossierOccupants(original).first.firstName, original.firstName);
      expect(dossierIdentityNeedsReview(original), isTrue);
    }
    expect(dossierIdentityNeedsReview(patient()), isFalse);
  });
  test('blank civility stays blank and no name guesses gender', () {
    expect(
      dossierOccupantDisplayName(
        const Occupant(
          firstName: 'Camille',
          lastName: 'Test',
          gender: '',
          maidenName: '',
        ),
        0,
      ),
      'TEST Camille',
    );
    expect(dossierOccupants(patient()).every((o) => o.gender == null), isTrue);
  });

  test(
    'two imported full names become distinct rows and one shared surname title',
    () {
      final imported = patient(
        lastName: 'LECUYER Daniel',
        firstName: 'LECUYER Heike',
        occupants: const [
          Occupant(
            apa: true,
            apaGir: '3',
            gender: 'Homme',
            birthDate: '1948-04-12',
          ),
          Occupant(homeHelpTxt: 'Aide deuxième personne', gender: 'Femme'),
        ],
      );
      final rows = dossierOccupants(imported);
      expect(rows.map((o) => o.firstName), ['Daniel', 'Heike']);
      expect(rows.map((o) => o.lastName), ['LECUYER', 'LECUYER']);
      expect(rows[0].apaGir, '3');
      expect(rows[0].birthDate, '1948-04-12');
      expect(rows[1].homeHelpTxt, 'Aide deuxième personne');
      expect(rows.map((o) => o.gender), ['Homme', 'Femme']);
      expect(dossierBeneficiaryTitle(imported), 'Daniel et Heike Lecuyer');
      expect(imported.lastName, 'LECUYER Daniel');
    },
  );

  test(
    'full name normalization leaves ambiguous or already identified households intact',
    () {
      for (final imported in [
        patient(
          lastName: 'LECUYER Daniel',
          firstName: 'LECUYER Heike',
          count: 1,
        ),
        patient(
          lastName: 'LECUYER Daniel',
          firstName: 'LECUYER Heike',
          secondName: 'Alex',
        ),
        patient(lastName: 'LECUYER Daniel', firstName: 'MARTIN Heike'),
        patient(lastName: 'DE LA TOUR', firstName: 'DE LA RUE'),
      ]) {
        expect(dossierOccupants(imported).first.firstName, imported.firstName);
        expect(dossierOccupants(imported).first.lastName, imported.lastName);
      }
    },
  );

  test('header groups shared surnames and preserves distinct surnames', () {
    final imported = patient(
      firstName: 'DANIEL',
      lastName: 'LECUYER',
      occupants: const [
        Occupant(firstName: 'DANIEL', lastName: 'LECUYER'),
        Occupant(firstName: 'Heike', lastName: 'Lecuyer'),
      ],
    );
    expect(dossierBeneficiaryTitle(imported), 'Daniel et Heike Lecuyer');
    expect(
      dossierBeneficiaryTitle(
        imported,
        occupants: const [
          Occupant(firstName: 'Daniel', lastName: 'LECUYER'),
          Occupant(firstName: 'Heike', lastName: 'MARTIN'),
        ],
      ),
      'Daniel Lecuyer et Heike Martin',
    );
    expect(dossierBeneficiaryTitle(patient()), 'René et Madeleine Exemple');
  });

  test(
    'clear joint names split without moving or losing existing visit details',
    () {
      final original = patient(
        occupants: const [
          Occupant(
            firstName: 'René et Madeleine',
            lastName: 'Exemple',
            apa: true,
            apaGir: '3',
            fiscalRevenue: 12000,
            birthDate: '1948-04-12',
          ),
          Occupant(homeHelpTxt: 'Aide conservée', gender: 'Femme'),
        ],
      );
      final rows = dossierOccupants(original);
      expect(rows.map((o) => o.firstName), ['René', 'Madeleine']);
      expect(rows.map((o) => o.lastName), ['Exemple', 'Exemple']);
      expect(rows.first.apaGir, '3');
      expect(rows.first.fiscalRevenue, 12000);
      expect(rows.first.birthDate, '1948-04-12');
      expect(rows[1].homeHelpTxt, 'Aide conservée');
      expect(rows[1].gender, 'Femme');
      expect(rows.first.gender, isNull); // Never infer from a first name.
      expect(original.occupants.first.firstName, 'René et Madeleine');
    },
  );

  test('ambiguous names and identified second occupants are not split', () {
    expect(
      dossierOccupants(
        patient(firstName: 'Marie Claire et Jean'),
      ).first.firstName,
      'Marie Claire et Jean',
    );
    expect(
      dossierOccupants(patient(secondName: 'Alex')).first.firstName,
      'René et Madeleine',
    );
    expect(
      dossierOccupants(patient(count: 1)).first.firstName,
      'René et Madeleine',
    );
  });

  test(
    'legacy scalar health fields survive initialization and gender editing',
    () {
      final rows = dossierOccupants(patient());
      final edited = rows.first.copyWith(gender: 'Homme');
      expect(edited.apa, isTrue);
      expect(edited.homeHelpTxt, 'Aide conservée');
      expect(edited.birthDate, '1948-04-12');
      expect(Occupant.fromJson(edited.toJson()).gender, 'Homme');
    },
  );

  test('absent legacy gender stays absent; clearing is explicit', () {
    final legacy = Occupant.fromJson({'firstName': 'Alex'});
    expect(legacy.toJson().containsKey('gender'), isFalse);
    expect(legacy.copyWith(gender: '').toJson()['gender'], '');
    expect(
      legacy.copyWith(gender: 'Femme').copyWith(homeHelp: true).gender,
      'Femme',
    );
  });

  test('existing households are never truncated by a lower declared count', () {
    expect(
      dossierOccupants(
        patient(count: 1, occupants: List.generate(6, (_) => const Occupant())),
      ).length,
      6,
    );
  });
}
