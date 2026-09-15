import '../models/types.dart';

bool matchesWikiSearch(WikiItem item, String query) {
  final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
  final text = '${item.title} ${item.description} ${item.tags.join(' ')}'
      .toLowerCase();
  return terms.every(text.contains);
}
