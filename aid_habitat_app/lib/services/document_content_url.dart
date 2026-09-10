import '../models/types.dart';
import 'app_config.dart';

String documentPreviewUrl(DocItem doc) => versionedDocumentUrl(
  doc.url ?? '',
  doc.updatedAt.trim().isNotEmpty ? doc.updatedAt : doc.date,
);

String versionedDocumentUrl(String raw, String version) {
  raw = raw.trim();
  version = version.trim();
  final uri = Uri.tryParse(raw);
  final api = Uri.tryParse(AppConfig.apiBaseUrl);
  // Do not rewrite signed third-party URLs.
  if (version.isEmpty ||
      uri == null ||
      (uri.hasAuthority &&
          (api == null ||
              !const ['http', 'https'].contains(uri.scheme) ||
              !const ['http', 'https'].contains(api.scheme) ||
              uri.origin != api.origin)) ||
      !uri.path.startsWith('/api/mobile-documents/')) {
    return raw;
  }
  return uri
      .replace(
        queryParameters: {
          ...uri.queryParametersAll,
          'preview_v': [version],
        },
      )
      .toString();
}
