import 'package:aid_habitat_app/data/mock_data.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/dossier_workflow.dart';
import 'package:flutter_test/flutter_test.dart';

Dossier dossier({
  String? stage = '1a. Rendez-vous à Prendre',
  String? visit = '2026-10-16T08:00:00Z',
  String? sent,
  DossierStatus status = DossierStatus.TO_VISIT,
}) {
  final sample = MOCK_DOSSIERS.first;
  return Dossier(
    id: 'airtable:synthetic',
    patient: sample.patient,
    status: status,
    ergoId: 'Coralie',
    visitDate: visit,
    airtableStage: stage,
    airtableReportSentDate: sent,
    housing: sample.housing,
    autonomyNotes: '',
    plans: {},
    createdAt: '2026-10-01',
  );
}

void main() {
  final today = DateTime.utc(2026, 10, 16, 14);
  DossierBucket? bucket(Dossier input) => dossierBucket(input, now: today);

  test('today stays to visit until the next Paris calendar day', () {
    final input = dossier();
    expect(bucket(input), DossierBucket.visiteAFaire);
    expect(
      dossierBucket(input, now: DateTime.utc(2026, 10, 16, 21, 59)),
      DossierBucket.visiteAFaire,
    );
    expect(
      dossierBucket(input, now: DateTime.utc(2026, 10, 16, 22)),
      DossierBucket.rapportAFaire,
    );
  });

  test('only step 1a with a scheduled appointment is to visit', () {
    expect(bucket(dossier(visit: '2026-10-20')), DossierBucket.visiteAFaire);
    for (final stage in [
      '1b. Rendez-vous pris',
      '2. Envoi du dossier',
      '',
      '1ab',
    ]) {
      expect(bucket(dossier(stage: stage)), isNull);
    }
    for (final visit in [null, '', 'invalid']) {
      expect(bucket(dossier(visit: visit)), isNull);
    }
  });

  test(
    'a past appointment without sending is pending regardless of stale status',
    () {
      for (final status in [
        DossierStatus.TO_VISIT,
        DossierStatus.VISITED,
        DossierStatus.IN_PROGRESS,
      ]) {
        expect(
          bucket(
            dossier(
              stage: '2. Envoi du dossier',
              visit: '2026-10-15',
              status: status,
            ),
          ),
          DossierBucket.rapportAFaire,
        );
      }
      expect(
        bucket(dossier(status: DossierStatus.VISITED)),
        DossierBucket.visiteAFaire,
      );
    },
  );

  test(
    'sending date takes priority even with a stale visit status or no appointment',
    () {
      for (final visit in [null, '2026-10-15', '2026-10-20']) {
        expect(
          bucket(dossier(visit: visit, sent: '2026-10-16')),
          DossierBucket.rapportEnvoye,
        );
      }
      expect(
        bucket(dossier(visit: '2026-10-15', sent: '')),
        DossierBucket.rapportAFaire,
      );
    },
  );

  test('cancelled dossiers stay excluded even if a report was sent', () {
    expect(bucket(dossier(stage: 'Annulé', sent: '2026-10-16')), isNull);
  });

  test('legacy reports require a past appointment', () {
    expect(
      bucket(dossier(stage: null, status: DossierStatus.VISITED)),
      DossierBucket.visiteAFaire,
    );
    expect(
      bucket(dossier(stage: null, visit: null, status: DossierStatus.VISITED)),
      isNull,
    );
    expect(
      bucket(dossier(stage: null, status: DossierStatus.IN_PROGRESS)),
      DossierBucket.rapportEnvoye,
    );
  });

  test('copyWith preserves Airtable workflow fields', () {
    final copy = dossier(
      sent: '2026-10-16',
    ).copyWith(status: DossierStatus.VISITED);
    expect(copy.airtableStage, '1a. Rendez-vous à Prendre');
    expect(copy.airtableReportSentDate, '2026-10-16');
  });

  test('visit day is interpreted in Paris across midnight and winter time', () {
    expect(
      bucket(dossier(visit: '2026-10-15T22:30:00Z')),
      DossierBucket.visiteAFaire,
    );
    expect(
      dossierBucket(
        dossier(visit: '2026-12-15T23:30:00Z'),
        now: DateTime.utc(2026, 12, 16, 12),
      ),
      DossierBucket.visiteAFaire,
    );
  });
}
