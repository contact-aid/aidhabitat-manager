import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Only app-owned durable document subtrees may be relocated. Never search
/// by basename: another revision may have the same content.pdf filename.
String? documentStorageKey(String path) {
  final marker = path.lastIndexOf('/Documents/');
  final relative = marker >= 0 ? path.substring(marker + 11) : path;
  final parts = p.posix.split(relative);
  if (parts.length < 2 ||
      !const [
        'document_revisions',
        'offline_documents',
      ].contains(parts.first) ||
      parts.any((part) => part == '..' || part == '.' || part.isEmpty)) {
    return null;
  }
  return p.posix.joinAll(parts);
}

Future<String> resolveDocumentStoragePath(
  String storedPath, {
  Future<Directory> Function()? documentsDirectory,
}) async {
  if (storedPath.isEmpty || await File(storedPath).exists()) return storedPath;
  final key = documentStorageKey(storedPath);
  if (key == null) return storedPath;
  final root = await (documentsDirectory ?? getApplicationDocumentsDirectory)();
  final candidate = File(p.join(root.path, key));
  if (!await candidate.exists()) return storedPath;
  final resolved = await candidate.resolveSymbolicLinks();
  final resolvedRoot = await root.resolveSymbolicLinks();
  return p.isWithin(resolvedRoot, resolved) ? candidate.path : storedPath;
}
