import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/services/context_sync_protocol.dart';

const _write1 = '11111111-1111-4111-8111-111111111111';
const _write2 = '22222222-2222-4222-8222-222222222222';
const _write3 = '33333333-3333-4333-8333-333333333333';
const _remote1 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _remote2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

Map<String, dynamic> medical(String pathology) => {
  'pathology': pathology,
  'followUp': '',
  'sensory': '',
  'heightCm': '170',
  'weightKg': '70',
};

Map<String, dynamic> autonomy(bool done) => {
  'done': done,
  'checklist': [
    {'name': 'Déplacements/transferts', 'checked': done},
  ],
  'occupants': <dynamic>[],
};

const reference1 = ContextServerReference(
  recordId: 42,
  revision: _remote1,
  updatedAt: '2026-09-10T08:00:00.000Z',
);

void main() {
  test('les éditions successives gardent la base serveur initiale', () {
    final first = ContextMutationEnvelope.begin(
      dossierId: 'dossier-1',
      updates: {'medicalContext': medical('local 1')},
      valuesBeforeEdit: {'medicalContext': medical('serveur')},
      serverReference: reference1,
      writeId: _write1,
    );
    final second = first.addEdits(
      updates: {
        'medicalContext': medical('local 2'),
        'autonomy': autonomy(true),
      },
      valuesBeforeEdit: {
        'medicalContext': medical('local 1'),
        'autonomy': autonomy(false),
      },
      nextWriteId: _write2,
    );

    expect(second.updates['medicalContext'], medical('local 2'));
    expect(second.baseValues['medicalContext'], medical('serveur'));
    expect(second.baseValues['autonomy'], autonomy(false));
    expect(second.serverReference?.revision, _remote1);
    expect(second.generation, 2);
  });

  test('réponse perdue et redémarrage conservent exactement le writeId', () {
    final pending = ContextMutationEnvelope.begin(
      dossierId: 'dossier-1',
      updates: {'medicalContext': medical('hors ligne')},
      valuesBeforeEdit: {'medicalContext': medical('serveur')},
      serverReference: reference1,
      writeId: _write1,
    );
    final persisted = jsonEncode(pending.toJson());
    final afterRestart = ContextMutationEnvelope.fromJson(
      (jsonDecode(persisted) as Map).cast<String, dynamic>(),
    );

    expect(afterRestart.writeId, _write1);
    expect(afterRestart.toRequestJson(), pending.toRequestJson());
    expect(afterRestart.updates['medicalContext'], medical('hors ligne'));
  });

  test('un changement concurrent de medicalContext exige une décision', () {
    final pending = ContextMutationEnvelope.begin(
      dossierId: 'dossier-1',
      updates: {'medicalContext': medical('local')},
      valuesBeforeEdit: {'medicalContext': medical('base')},
      serverReference: reference1,
      writeId: _write1,
    );
    final comparison = pending.compareWith(
      remoteValues: {
        'medicalContext': medical('distant'),
        'autonomy': autonomy(false),
      },
      remoteReference: const ContextServerReference(
        recordId: 42,
        revision: _remote2,
      ),
    );
    final conflicted = pending.recordConflict(comparison);

    expect(comparison.plan.conflicts, ['medicalContext']);
    expect(comparison.plan.updates, isEmpty);
    expect(
      conflicted.conflict?.remoteValues['medicalContext'],
      medical('distant'),
    );
    expect(
      () => conflicted.addEdits(
        updates: {'autonomy': autonomy(true)},
        valuesBeforeEdit: {'autonomy': autonomy(false)},
        nextWriteId: _write2,
      ),
      throwsStateError,
    );
  });

  test('choisir local crée une nouvelle garde basée sur le distant', () {
    final pending = ContextMutationEnvelope.begin(
      dossierId: 'dossier-1',
      updates: {'medicalContext': medical('local')},
      valuesBeforeEdit: {'medicalContext': medical('base')},
      serverReference: reference1,
      writeId: _write1,
    );
    final conflicted = pending.recordConflict(
      pending.compareWith(
        remoteValues: {
          'medicalContext': medical('distant'),
          'autonomy': autonomy(false),
        },
        remoteReference: const ContextServerReference(
          recordId: 42,
          revision: _remote2,
        ),
      ),
    );
    final resolved = conflicted.resolveConflict(
      decisions: {'medicalContext': 'local'},
      nextWriteId: _write2,
    );

    expect(resolved.valuesToStoreLocally['medicalContext'], medical('local'));
    expect(
      resolved.pendingMutation?.updates['medicalContext'],
      medical('local'),
    );
    expect(
      resolved.pendingMutation?.baseValues['medicalContext'],
      medical('distant'),
    );
    expect(resolved.pendingMutation?.serverReference?.revision, _remote2);
    expect(resolved.pendingMutation?.writeId, _write2);
  });

  test('choisir distant conserve le serveur et termine la mutation', () {
    final pending = ContextMutationEnvelope.begin(
      dossierId: 'dossier-1',
      updates: {'medicalContext': medical('local')},
      valuesBeforeEdit: {'medicalContext': medical('base')},
      serverReference: reference1,
      writeId: _write1,
    );
    final conflicted = pending.recordConflict(
      pending.compareWith(
        remoteValues: {
          'medicalContext': medical('distant'),
          'autonomy': autonomy(false),
        },
        remoteReference: const ContextServerReference(
          recordId: 42,
          revision: _remote2,
        ),
      ),
    );
    final resolved = conflicted.resolveConflict(
      decisions: {'medicalContext': 'remote'},
      nextWriteId: _write2,
    );

    expect(resolved.valuesToStoreLocally['medicalContext'], medical('distant'));
    expect(resolved.pendingMutation, isNull);
  });

  test('une modification locale invalide une comparaison déjà calculée', () {
    final first = ContextMutationEnvelope.begin(
      dossierId: 'dossier-1',
      updates: {'medicalContext': medical('local 1')},
      valuesBeforeEdit: {'medicalContext': medical('base')},
      serverReference: reference1,
      writeId: _write1,
    );
    final comparison = first.compareWith(
      remoteValues: {
        'medicalContext': medical('base'),
        'autonomy': autonomy(false),
      },
      remoteReference: reference1,
    );
    final second = first.addEdits(
      updates: {'medicalContext': medical('local 2')},
      valuesBeforeEdit: {'medicalContext': medical('local 1')},
      nextWriteId: _write3,
    );

    expect(first.isComparisonCurrent(comparison), isTrue);
    expect(second.isComparisonCurrent(comparison), isFalse);
    expect(() => second.recordConflict(comparison), throwsStateError);
  });

  test('une modification distante non chevauchante reste fusionnable', () {
    final pending = ContextMutationEnvelope.begin(
      dossierId: 'dossier-1',
      updates: {'medicalContext': medical('local')},
      valuesBeforeEdit: {'medicalContext': medical('base')},
      serverReference: reference1,
      writeId: _write1,
    );
    final comparison = pending.compareWith(
      remoteValues: {
        'medicalContext': medical('base'),
        'autonomy': autonomy(true),
      },
      remoteReference: const ContextServerReference(
        recordId: 42,
        revision: _remote2,
      ),
    );

    expect(comparison.plan.requiresReview, isFalse);
    expect(comparison.plan.updates['medicalContext'], medical('local'));
  });
}
