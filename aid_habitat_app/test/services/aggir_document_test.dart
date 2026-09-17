import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/models/aggir_eligibility.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/aggir_document_service.dart';
import 'package:aid_habitat_app/services/document_repository.dart';

Patient patient(String birthday, {List<Occupant> occupants = const []}) =>
    Patient(
      id: 'test-primary',
      firstName: 'Élodie',
      lastName: 'DUPONT',
      birthDate: birthday,
      phone: '',
      email: '',
      address: '16 rue des Érables',
      city: 'Chartres-de-Bretagne',
      zipCode: '35131',
      familySituation: '',
      incomeCategory: '',
      occupants: occupants,
      trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
    );

Dossier dossier(Patient p) => Dossier(
  id: 'test-dossier',
  patient: p,
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
);

class MemoryDocuments extends DocumentRepository {
  List<DocItem> docs = [];
  int writes = 0;
  List<int>? pdf;

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
    pdf = bytes;
    final doc = DocItem(
      id: localId!,
      type: 'pdf',
      name: fileName,
      title: title!,
      tags: tags,
      date: '2026-09-17',
    );
    docs.add(doc);
    return doc;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final today = DateTime(2026, 9, 17);
  test('exact age boundaries and unknown or impossible dates', () {
    for (final birth in [
      '',
      'unknown',
      '1961-02-30',
      '31/02/1961',
      '2027-01-01',
      '1966-09-18',
      '1956-09-17',
    ]) {
      expect(requiresAggir(birth, today: today), isFalse, reason: birth);
    }
    for (final birth in ['1966-09-17', '1956-09-18', '17/09/1966']) {
      expect(requiresAggir(birth, today: today), isTrue, reason: birth);
    }
  });

  test('only the primary occupant counts, even when their age is unknown', () {
    expect(
      primaryBeneficiaryRequiresAggir(
        patient(
          '1940-01-01',
          occupants: [
            const Occupant(birthDate: '1940-01-01'),
            const Occupant(birthDate: '1961-01-01'),
          ],
        ),
        today: today,
      ),
      isFalse,
    );
    expect(
      primaryBeneficiaryRequiresAggir(
        patient(
          '1961-01-01',
          occupants: [
            const Occupant(),
            const Occupant(birthDate: '1961-01-01'),
          ],
        ),
        today: today,
      ),
      isFalse,
    );
    expect(
      primaryBeneficiaryRequiresAggir(patient('1961-01-01'), today: today),
      isTrue,
    );
  });

  test(
    'create once offline, serialize concurrent loads, preserve signed form',
    () async {
      final repo = MemoryDocuments();
      final service = AggirDocumentService(repository: repo);
      final birth = '${DateTime.now().year - 65}-01-01';
      final d = dossier(patient(birth));
      expect(await service.documentsFor(d, createIfMissing: false), isEmpty);
      await Future.wait([service.documentsFor(d), service.documentsFor(d)]);
      expect(repo.writes, 1);
      expect(repo.pdf!.take(5), '%PDF-'.codeUnits);
      final signed = repo.docs.single.copyWith(
        annotationsJson: '{"1":"signed"}',
      );
      repo.docs = [signed];
      expect((await service.documentsFor(d)).single, same(signed));
      expect(repo.writes, 1);
      expect(await service.documentsFor(dossier(patient(''))), isEmpty);
      expect(repo.docs.single.annotationsJson, '{"1":"signed"}');
      expect((await service.documentsFor(d)).single, same(signed));
    },
  );

  test(
    'prefill PDF from the supplied template for visual verification',
    () async {
      final bytes = await AggirDocumentService.buildPdf(
        patient('1961-01-01'),
        today: today,
      );
      expect(bytes.take(5), '%PDF-'.codeUnits);
      final output = Platform.environment['AGGIR_QA_PDF'];
      if (output != null) await File(output).writeAsBytes(bytes);
    },
  );
}
