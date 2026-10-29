String aiRewriteContextForTab(String tabKey) {
  final key = tabKey.toLowerCase();
  if (key == 'bénéficiaire-notes') return 'living_context';
  if (key.contains('médical') || key.contains('medical')) {
    return 'medical';
  }
  if (key.contains('autonomie')) {
    return 'autonomy';
  }
  if (key.contains('aide') || key.contains('entourage')) {
    return 'human_help';
  }
  if (key.contains('contexte')) {
    return 'living_context';
  }
  if (key.contains('bénéficiaire') || key.contains('beneficiaire')) {
    return 'beneficiary';
  }
  if (key.contains('préconisation') || key.contains('preconisation')) {
    return 'recommendations';
  }
  if (key.contains('logement') || key.contains('accessibilité')) {
    return 'housing';
  }
  return 'general';
}
