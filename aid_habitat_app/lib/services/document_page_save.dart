/// Retains failed and unattempted pages so a partial save can be retried.
Future<void> persistDirtyDocumentPages({
  required Set<int> dirtyPages,
  required Future<void> Function(int page) persistPage,
}) async {
  for (final page in dirtyPages.toList()) {
    await persistPage(page);
    dirtyPages.remove(page);
  }
}
