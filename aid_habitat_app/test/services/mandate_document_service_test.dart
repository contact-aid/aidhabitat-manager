import 'dart:io';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/document_repository.dart';
import 'package:aid_habitat_app/services/mandate_document_service.dart';
import 'package:flutter_test/flutter_test.dart';

Patient _patient() => Patient(
  id: 'fictional-patient',
  firstName: 'Élodie',
  lastName: 'DUPONT',
  birthDate: '1957-05-14',
  phone: '0102030405',
  email: 'elodie@example.invalid',
  address: '12 rue des Lilas',
  city: 'Rennes',
  zipCode: '35000',
  familySituation: '',
  occupationStatus: 'Propriétaire',
  incomeCategory: '',
  trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
);

Dossier _dossier(String compteAnah) => Dossier(
  id: 'fictional-dossier',
  patient: _patient(),
  status: DossierStatus.values.first,
  ergoId: '',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.OTHER,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: {},
  createdAt: '',
  compteAnah: compteAnah,
);

LocalAppUser _user(String id, String email, String name) => LocalAppUser(
  id: id,
  email: email,
  displayName: name,
  role: LocalUserRole.ergo,
);

class _MemoryDocuments extends DocumentRepository {
  final docs = <DocItem>[];
  var writes = 0;

  @override
  Future<List<DocItem>> fetchDocuments(String patientId) async => [...docs];

  @override
  Future<DocItem> importDocumentBytes({
    required String patientId,
    required List<int> bytes,
    required String fileName,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
    String? dossierId,
    String? localId,
  }) async {
    writes++;
    expect(bytes.length, greaterThan(100000));
    final doc = DocItem(
      id: localId!,
      type: 'pdf',
      name: fileName,
      title: title!,
      date: '2026-09-30',
      tags: tags,
    );
    docs.add(doc);
    return doc;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only Aid’habitat mandates trigger generation', () {
    expect(
      MandateDocumentService.isRequested(
        _dossier('{"mandat":"Oui","mandatPar":"Aid\'habitat"}'),
      ),
      isTrue,
    );
    for (final value in [
      '',
      'Mandat',
      '{"mandat":"Non","mandatPar":"Aid\'habitat"}',
      '{"mandat":"Oui","mandatPar":"Autre"}',
    ]) {
      expect(MandateDocumentService.isRequested(_dossier(value)), isFalse);
    }
  });

  test('selects the signed account template and the generic template', () {
    expect(
      MandateDocumentService.templateFor(
        _user('c', 'c.demenais@aidhabitat.fr', 'Coralie'),
      ),
      'mandat_coralie',
    );
    expect(
      MandateDocumentService.templateFor(
        _user('j', 'c.jeuland@aidhabitat.fr', 'Christelle'),
      ),
      'mandat_christelle',
    );
    expect(
      MandateDocumentService.templateFor(
        _user('f', 'f.cribier@aidhabitat.fr', 'Fabien CRIBIER'),
      ),
      'mandat_administratif',
    );
  });

  test('creates once per account and keeps an existing mandate', () async {
    final repository = _MemoryDocuments();
    final service = MandateDocumentService(repository: repository);
    final dossier = _dossier('{"mandat":"Oui","mandatPar":"Aid\'habitat"}');
    final coralie = _user('c', 'c.demenais@aidhabitat.fr', 'Coralie');
    final christelle = _user('j', 'c.jeuland@aidhabitat.fr', 'Christelle');

    await Future.wait([
      service.documentsFor(dossier, coralie),
      service.documentsFor(dossier, coralie),
    ]);
    expect(repository.writes, 1);
    await service.documentsFor(dossier, coralie);
    expect(repository.writes, 1);
    await service.documentsFor(dossier, christelle);
    expect(repository.writes, 2);
    expect(repository.docs.map((doc) => doc.id).toSet().length, 2);
  });

  test('produces the three two-page PDFs for visual QA', () async {
    final qaDir = Platform.environment['MANDATE_QA_DIR'];
    for (final user in [
      _user('c', 'c.demenais@aidhabitat.fr', 'Coralie'),
      _user('j', 'c.jeuland@aidhabitat.fr', 'Christelle'),
      _user('f', 'f.cribier@aidhabitat.fr', 'Fabien CRIBIER'),
    ]) {
      final bytes = await MandateDocumentService.buildPdf(_patient(), user);
      expect(bytes.length, greaterThan(100000));
      if (qaDir != null) {
        await File(
          '$qaDir/${MandateDocumentService.templateFor(user)}.pdf',
        ).writeAsBytes(bytes);
      }
    }
  });
}
