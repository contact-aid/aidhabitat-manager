import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'native_file_protection.dart';

/// A revision is written and flushed before SQLite can reference it. Existing
/// files are never overwritten, including files still used by an upload/viewer.
class DocumentRevisionStore {
  DocumentRevisionStore({Future<Directory> Function()? documentsDirectory})
    : _documentsDirectory =
          documentsDirectory ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDirectory;

  Future<File> prepare({
    required String extension,
    List<int>? bytes,
    File? sourceFile,
    String? annotationSourcePath,
  }) async {
    if ((bytes == null) == (sourceFile == null)) {
      throw ArgumentError('Exactly one document source is required');
    }
    if (!RegExp(r'^[a-z0-9]{1,10}$').hasMatch(extension)) {
      throw ArgumentError.value(extension, 'extension');
    }
    final root = await _documentsDirectory();
    final revisions = await NativeFileProtection.instance
        .ensureProtectedDirectory(p.join(root.path, 'document_revisions'));
    final directory = await revisions.createTemp('revision_');
    try {
      await NativeFileProtection.instance.protectPath(directory.path);
      final path = p.join(directory.path, 'content.$extension');
      final file = bytes != null
          ? await NativeFileProtection.instance.writeProtectedBytes(path, bytes)
          : await _copyAndFlush(sourceFile!, path);
      if (await file.length() == 0) {
        throw const FileSystemException('Le document produit est vide');
      }
      // PDF strokes currently live beside the PDF, not in its bytes. Keep
      // those sidecars when changing the file path; never copy rendered PNGs.
      if (annotationSourcePath != null) {
        final source = File(annotationSourcePath);
        final prefix = p.basename(source.path);
        final sidecar = RegExp(
          '^${RegExp.escape(prefix)}(?:\\.page[0-9]+\\.png)?\\.annotation\\.json\$',
        );
        if (await source.parent.exists()) {
          await for (final entry in source.parent.list(followLinks: false)) {
            final name = p.basename(entry.path);
            if (entry is File && sidecar.hasMatch(name)) {
              await _copyAndFlush(
                entry,
                '$path${name.substring(prefix.length)}',
              );
            }
          }
        }
      }
      return file;
    } catch (_) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // An unreferenced partial revision is safer than touching the original.
      }
      rethrow;
    }
  }

  Future<File> _copyAndFlush(File source, String path) async {
    final file = await NativeFileProtection.instance.copyProtectedFile(
      source,
      path,
    );
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    return file;
  }
}
