import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/wiki_search.dart';

void main() {
  const item = WikiItem(
    id: 'test',
    title: 'Barre appui angle',
    description: 'Fixation murale pour la douche.',
    imageUrl: '',
    tags: ['Salle de bain'],
    category: 'Salle de bain',
    createdAt: '',
    updatedAt: '',
  );

  for (final query in [
    'barre angle',
    'angle barre',
    '  BARRE   angle  ',
    'barre\tangle\n',
    'barre douche',
    'angle bain',
    'barr angl',
    'barre',
    '',
    '   ',
  ]) {
    test('matches independent keywords: "$query"', () {
      expect(matchesWikiSearch(item, query), isTrue);
    });
  }

  for (final query in ['barre cuisine', 'angle escalier', 'robinet']) {
    test('requires every keyword: "$query"', () {
      expect(matchesWikiSearch(item, query), isFalse);
    });
  }
}
