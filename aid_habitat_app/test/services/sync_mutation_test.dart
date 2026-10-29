import 'dart:convert';

import 'package:aid_habitat_app/services/sync_mutation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'latest occupant pension preserves independent server health and unknown properties',
    () {
      final merged = mergeLatestPatientValues(
        baseline: {
          'email': '',
          'phone': 'old',
          'occupants': [
            {
              'firstName': 'Alice',
              'lastName': 'Test',
              'homeHelp': false,
              'caisseRetraitePrincipale': 'Avant',
            },
          ],
        },
        local: {
          'email': '',
          'phone': '',
          'occupants': [
            {
              'firstName': 'Alice',
              'lastName': 'Test',
              'homeHelp': false,
              'caisseRetraitePrincipale': 'CNAV',
            },
          ],
        },
        remote: {
          'email': 'server@example.test',
          'phone': 'old',
          'occupants': [
            {
              'firstName': 'Alice',
              'lastName': 'Test',
              'homeHelp': true,
              'caisseRetraitePrincipale': 'Avant',
              'futureProperty': 'retained',
            },
          ],
        },
      );
      expect(merged['email'], 'server@example.test');
      expect(merged['phone'], '');
      expect(merged['occupants'][0]['caisseRetraitePrincipale'], 'CNAV');
      expect(merged['occupants'][0]['homeHelp'], true);
      expect(merged['occupants'][0]['futureProperty'], 'retained');
      expect(
        () => mergeLatestPatientValues(
          baseline: {
            'occupants': [
              {'firstName': 'Alice'},
            ],
          },
          local: {
            'occupants': [
              {'firstName': 'Alice', 'homeHelp': true},
            ],
          },
          remote: {
            'occupants': [
              {'firstName': 'Bob'},
            ],
          },
        ),
        throwsStateError,
      );
    },
  );

  test(
    'entered phone fills an empty server value even with an edited or absent baseline',
    () {
      for (final before in [null, '', 'old']) {
        final plan = planSyncMerge(
          baseValues: {'phone': before},
          updates: {'phone': '123'},
          remoteValues: {'phone': null},
        );
        expect(plan.canApplyAutomatically, isTrue);
        expect(plan.updates, {'phone': '123'});
      }
      expect(
        planSyncMerge(
          baseValues: {},
          updates: {'phone': '123'},
          remoteValues: {'phone': null},
        ).canApplyAutomatically,
        isTrue,
      );
      expect(
        () => mergeLatestPatientValues(
          baseline: {'phone': 'old'},
          local: {'phone': 'local'},
          remote: {'phone': 'server'},
        ),
        throwsStateError,
      );
      expect(
        mergeLatestPatientValues(
          baseline: {
            'occupants': [
              {'firstName': 'A', 'homeHelp': false},
            ],
          },
          local: {
            'occupants': [
              {'firstName': 'A', 'homeHelp': true},
            ],
          },
          remote: {
            'occupants': [
              {'firstName': 'A', 'homeHelp': null},
            ],
          },
        )['occupants'][0]['homeHelp'],
        isTrue,
      );
    },
  );

  test(
    'entered nullable answers win over empty values in either direction',
    () {
      for (final answer in [true, false]) {
        final local = planSyncMerge(
          baseValues: {'easyAccess': answer},
          updates: {'easyAccess': answer},
          remoteValues: {'easyAccess': null},
        );
        expect(local.canApplyAutomatically, isTrue);
        expect(local.updates, {'easyAccess': answer});
        final remote = planSyncMerge(
          baseValues: {'easyAccess': null},
          updates: {'easyAccess': null},
          remoteValues: {'easyAccess': answer},
        );
        expect(remote.canApplyAutomatically, isTrue);
        expect(remote.updates, isEmpty);
      }
      expect(
        planSyncMerge(
          baseValues: {'easyAccess': null},
          updates: {'easyAccess': false},
          remoteValues: {'easyAccess': true},
        ).conflictingFields,
        ['easyAccess'],
      );
    },
  );

  test('occupant defaults do not block a real APA edit', () {
    final original = {'firstName': 'Anne', 'lastName': 'Fictif', 'apa': false};
    final projected = {
      ...original,
      'apaGir': '',
      'apaDetails': '',
      'invalidityDetails': '',
      'fiscalReferenceYear': '',
      'fiscalRevenue': null,
    };
    final changed = {...projected, 'apa': true};
    final plan = planSyncMerge(
      baseValues: {
        'occupants': [projected],
      },
      updates: {
        'occupants': [changed],
      },
      remoteValues: {
        'occupants': [original],
      },
    );
    expect(plan.canApplyAutomatically, isTrue);
    expect(plan.updates['occupants'], [changed]);
    expect(equivalentSyncField('occupants', [projected], [original]), isTrue);
    expect(
      equivalentSyncField(
        'occupants',
        [projected],
        [
          {...original, 'fiscalRevenue': 0},
        ],
      ),
      isFalse,
    );
    final differences = occupantConflictDifferences([changed], [original])!;
    expect(differences.length, 1);
    expect(differences.single.label, 'Anne Fictif · APA');
    expect(differences.single.local, isTrue);
    expect(differences.single.remote, isFalse);
  });

  test('ambiguous and reordered occupants are never compared by position', () {
    final a = {'firstName': 'Anne', 'lastName': 'Fictif'};
    final b = {'firstName': 'Bob', 'lastName': 'Fictif'};
    expect(occupantConflictDifferences([a, b], [b, a]), isNull);
    expect(occupantConflictDifferences([a, a], [a, a]), isNull);
  });

  test(
    'conflict explanation distinguishes local and remote version changes',
    () {
      expect(
        describeSyncConflict({
          'conflict': {'code': 'LOCAL_EDIT_BASE_CHANGED'},
        }),
        contains('fiche locale'),
      );
      expect(describeSyncConflict({}), contains('absente'));
      expect(
        describeSyncConflict({
          'concurrency': {'expectedUpdatedAt': '2026-09-01T10:00:00Z'},
          'conflict': {
            'remote': {'remoteUpdatedAt': '2026-09-01T10:01:00Z'},
          },
        }),
        contains('Référence : 2026-09-01T10:00:00Z'),
      );
      expect(
        describeSyncConflict({
          'conflict': {
            'remote': {'error': 'SYNC_FIELD_CONFLICT'},
          },
        }),
        contains('fusionnées'),
      );
    },
  );
  group('acknowledged successors', () {
    Map<String, dynamic> make(Map<String, dynamic>? previous) =>
        buildSyncMutation(
          idKey: 'patientLocalId',
          entityId: 'p1',
          updates: {
            'occupants': [
              {'invalidity': previous != null},
            ],
          },
          baseValues: {
            'occupants': [
              {'invalidity': false},
            ],
          },
          expectedUpdatedAt: '2026-09-01T10:00:00Z',
          previous: previous,
        );
    test(
      'rebase keeps latest occupant array, advances only acknowledged base',
      () {
        final sent = make(null);
        final pending = make(make(sent));
        final next = rebaseAcknowledgedMutation(
          sent: sent,
          pending: pending,
          version: '2026-09-01T10:01:00Z',
        )!;
        expect(next['updates'], pending['updates']);
        expect(next['concurrency']['baseValues'], sent['updates']);
        expect(
          next['concurrency']['expectedUpdatedAt'],
          '2026-09-01T10:01:00Z',
        );
        expect(
          rebaseAcknowledgedMutation(
            sent: sent,
            pending: next,
            version: '2026-09-01T10:01:00Z',
          ),
          isNull,
        );
      },
    );
    for (final reason in [
      'unrelated',
      'conflict',
      'changed-base',
      'changed-version',
      'unknown-base',
    ]) {
      test('reject $reason', () {
        final sent = make(null);
        final pending = reason == 'unrelated' ? make(null) : make(sent);
        if (reason == 'conflict') pending['conflict'] = {};
        if (reason == 'changed-base') {
          pending['concurrency']['baseValues'] = {'occupants': []};
        }
        if (reason == 'unknown-base') pending['concurrency']['baseValues'] = {};
        if (reason == 'changed-version') {
          pending['concurrency']['expectedUpdatedAt'] = '2026-09-02T10:00:00Z';
        }
        expect(
          rebaseAcknowledgedMutation(
            sent: sent,
            pending: pending,
            version: '2026-09-01T10:01:00Z',
          ),
          isNull,
        );
      });
    }
  });
  Map<String, dynamic> mutation({
    Map<String, dynamic>? previous,
    Map<String, dynamic> updates = const {'name': 'Local'},
    Map<String, dynamic> base = const {'name': 'Original'},
    String? version = 'server-v1',
  }) => buildSyncMutation(
    idKey: 'patientLocalId',
    entityId: 'patient-1',
    updates: updates,
    baseValues: base,
    expectedUpdatedAt: version,
    previous: previous,
  );

  test('a first edit captures only its known base values', () {
    final result = mutation(base: {'name': 'Original', 'phone': 'unrelated'});
    expect(result['updates'], {'name': 'Local'});
    expect(result['concurrency'], {
      'version': 1,
      'writeId': result['concurrency']['writeId'],
      'expectedUpdatedAt': 'server-v1',
      'baseValues': {'name': 'Original'},
    });
    expect(
      result['concurrency']['writeId'],
      matches(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ),
    );
  });
  test(
    'new edits rotate the id while serializing the same mutation preserves it',
    () {
      final first = mutation();
      final second = mutation(previous: first, updates: {'name': 'Next'});
      expect(
        second['concurrency']['writeId'],
        isNot(first['concurrency']['writeId']),
      );
      final restored = jsonDecode(jsonEncode(first));
      expect(
        restored['concurrency']['writeId'],
        first['concurrency']['writeId'],
      );
    },
  );
  test('successive edits retain the first baseline and server version', () {
    final result = mutation(
      previous: mutation(),
      updates: {'name': 'Local 2', 'phone': 'new phone'},
      base: {'name': 'Local', 'phone': 'old phone'},
      version: 'server-v2',
    );
    expect(result['updates'], {'name': 'Local 2', 'phone': 'new phone'});
    expect(result['concurrency']['baseValues'], {
      'name': 'Original',
      'phone': 'old phone',
    });
    expect(result['concurrency']['expectedUpdatedAt'], 'server-v1');
  });
  test('legacy queued fields do not acquire an invented baseline', () {
    final result = mutation(
      previous: {
        'updates': {'name': 'Previous'},
      },
      updates: {'name': 'New', 'phone': 'new phone'},
      base: {'name': 'Previous', 'phone': 'old phone'},
    );
    expect(result['concurrency']['baseValues'], {'phone': 'old phone'});
    expect(result['concurrency']['expectedUpdatedAt'], isNull);
  });
  test('missing base value stays unknown across further edits', () {
    final first = mutation(base: {});
    final result = mutation(previous: first);
    expect(result['concurrency']['baseValues'], isEmpty);
  });
  test('null is a captured value, not a missing value', () {
    expect(mutation(base: {'name': null})['concurrency']['baseValues'], {
      'name': null,
    });
  });
  test('nested values are detached from mutable form values', () {
    final old = {
      'contacts': [
        {'name': 'Old'},
      ],
    };
    final next = {
      'contacts': [
        {'name': 'New'},
      ],
    };
    final result = mutation(base: old, updates: next);
    old['contacts']!.single['name'] = 'Changed';
    next['contacts']!.clear();
    expect(result['concurrency']['baseValues'], {
      'contacts': [
        {'name': 'Old'},
      ],
    });
    expect(result['updates'], {
      'contacts': [
        {'name': 'New'},
      ],
    });
  });
  test('unknown future queue formats are not downgraded', () {
    expect(
      () => mutation(
        previous: {
          'updates': {'name': 'Local'},
          'concurrency': {'version': 2},
        },
      ),
      throwsStateError,
    );
  });

  test('independent field edits produce only the local patch', () {
    final plan = planSyncMerge(
      baseValues: {'name': 'Old', 'phone': 'Old phone'},
      updates: {'name': 'New'},
      remoteValues: {'name': 'Old', 'phone': 'New phone'},
    );
    expect(plan.canApplyAutomatically, isTrue);
    expect(plan.updates, {'name': 'New'});
  });
  test('different changes to the same field require a choice', () {
    final plan = planSyncMerge(
      baseValues: {'name': 'Old'},
      updates: {'name': 'Local'},
      remoteValues: {'name': 'Remote'},
    );
    expect(plan.canApplyAutomatically, isFalse);
    expect(plan.conflictingFields, ['name']);
  });
  test('identical remote value makes a lost-response retry a no-op', () {
    final plan = planSyncMerge(
      baseValues: {},
      updates: {'name': 'Local'},
      remoteValues: {'name': 'Local'},
    );
    expect(plan.canApplyAutomatically, isTrue);
    expect(plan.updates, isEmpty);
  });
  test('undoing the local edit does not undo a remote edit', () {
    final plan = planSyncMerge(
      baseValues: {'name': 'Old'},
      updates: {'name': 'Old'},
      remoteValues: {'name': 'Remote'},
    );
    expect(plan.canApplyAutomatically, isTrue);
    expect(plan.updates, isEmpty);
  });
  test('an unknown baseline requires a choice', () {
    final plan = planSyncMerge(
      baseValues: {},
      updates: {'name': 'Local'},
      remoteValues: {'name': 'Remote'},
    );
    expect(plan.conflictingFields, ['name']);
  });
  test('an absent remote field is not treated as null', () {
    final plan = planSyncMerge(
      baseValues: {'name': null},
      updates: {'name': 'Local'},
      remoteValues: {},
    );
    expect(plan.conflictingFields, ['name']);
  });
  test('explicit null baseline allows filling an empty remote field', () {
    final plan = planSyncMerge(
      baseValues: {'name': null},
      updates: {'name': 'Local'},
      remoteValues: {'name': null},
    );
    expect(plan.updates, {'name': 'Local'});
    expect(plan.canApplyAutomatically, isTrue);
  });
  test('structured fields compare JSON structure, not map insertion order', () {
    final plan = planSyncMerge(
      baseValues: {
        'person': {'name': 'Old', 'phone': '123'},
      },
      updates: {
        'person': {'name': 'Local', 'phone': '123'},
      },
      remoteValues: {
        'person': {'phone': '123', 'name': 'Old'},
      },
    );
    expect(plan.canApplyAutomatically, isTrue);
  });
  test('structured edits on both devices are conservatively conflicting', () {
    final plan = planSyncMerge(
      baseValues: {
        'person': {'name': 'Old', 'phone': '123'},
      },
      updates: {
        'person': {'name': 'Local', 'phone': '123'},
      },
      remoteValues: {
        'person': {'name': 'Old', 'phone': '456'},
      },
    );
    expect(plan.conflictingFields, ['person']);
  });
  test('occupants are never matched by array position after reordering', () {
    final plan = planSyncMerge(
      baseValues: {
        'occupants': ['A', 'B'],
      },
      updates: {
        'occupants': ['A modified', 'B'],
      },
      remoteValues: {
        'occupants': ['B', 'A'],
      },
    );
    expect(plan.canApplyAutomatically, isFalse);
  });
  test('one conflicting field prevents applying the whole proposal', () {
    final plan = planSyncMerge(
      baseValues: {'name': 'Old', 'phone': '123'},
      updates: {'name': 'Local', 'phone': '456'},
      remoteValues: {'name': 'Remote', 'phone': '123'},
    );
    expect(plan.canApplyAutomatically, isFalse);
    expect(plan.updates, {'phone': '456'});
  });

  test('a rapid successor note is rebased on its acknowledged write', () {
    const first = '11111111-1111-4111-8111-111111111111';
    const second = '22222222-2222-4222-8222-222222222222';
    const before = '00000000-0000-4000-8000-000000000000';
    const acknowledged = '33333333-3333-4333-8333-333333333333';
    final sent = {
      'patientLocalId': 'patient-1',
      'dossierId': 'dossier-1',
      'scopeType': 'visit_report',
      'scopeId': 'dossier-1',
      'tabKey': 'Contexte de vie-Médical',
      'pageNumber': 0,
      'drawingJson': 'first',
      'expectedRevision': before,
      'writeId': first,
      'predecessorWriteIds': <String>[],
    };
    final pending = {
      ...sent,
      'drawingJson': 'latest',
      'writeId': second,
      'predecessorWriteIds': [first],
    };

    final rebased = rebaseAcknowledgedNoteMutation(
      sent: sent,
      pending: pending,
      revision: acknowledged,
    );

    expect(rebased?['drawingJson'], 'latest');
    expect(rebased?['writeId'], second);
    expect(rebased?['expectedRevision'], acknowledged);
    expect(rebased?['predecessorWriteIds'], isEmpty);
  });

  test('a note is never rebased without proof of same-device succession', () {
    const first = '11111111-1111-4111-8111-111111111111';
    const second = '22222222-2222-4222-8222-222222222222';
    const acknowledged = '33333333-3333-4333-8333-333333333333';
    final sent = {
      'patientLocalId': 'patient-1',
      'tabKey': 'Contexte de vie-Médical',
      'pageNumber': 0,
      'expectedRevision': null,
      'writeId': first,
    };
    final unrelated = {
      ...sent,
      'writeId': second,
      'predecessorWriteIds': <String>[],
    };
    expect(
      rebaseAcknowledgedNoteMutation(
        sent: sent,
        pending: unrelated,
        revision: acknowledged,
      ),
      isNull,
    );
    expect(
      rebaseAcknowledgedNoteMutation(
        sent: sent,
        pending: {
          ...unrelated,
          'predecessorWriteIds': [first],
          'conflict': {'remote': 'other-device'},
        },
        revision: acknowledged,
      ),
      isNull,
    );
  });
}
