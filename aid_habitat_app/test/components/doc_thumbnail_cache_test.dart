import 'package:aid_habitat_app/components/doc_thumbnails.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/document_content_url.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('visual cache key changes when document content version changes', () {
    final before = DocItem(
      id: 'doc-1',
      type: 'pdf',
      name: 'devis sdb.pdf',
      title: 'devis sdb',
      date: '2026-08-31T10:00:00Z',
      updatedAt: '2026-08-31T10:00:00Z',
      localPath: '/tmp/devis-sdb.pdf',
    );
    final after = before.copyWith(updatedAt: '2026-08-31T10:03:00Z');

    expect(
      documentVisualCacheKey(after),
      isNot(documentVisualCacheKey(before)),
    );
  });

  test('document preview URL versions app document endpoints only', () {
    final doc = DocItem(
      id: 'doc-1',
      type: 'pdf',
      name: 'devis sdb.pdf',
      title: 'devis sdb',
      url: '/api/mobile-documents/doc-1/content',
      date: '2026-08-31T10:00:00Z',
      updatedAt: '2026-08-31T10:03:00Z',
    );
    final signedExternal = doc.copyWith(
      url: 'https://cdn.example.test/file.pdf?signature=abc',
    );

    expect(
      documentPreviewUrl(doc),
      '/api/mobile-documents/doc-1/content?preview_v=2026-08-31T10%3A03%3A00Z',
    );
    expect(
      documentPreviewUrl(signedExternal),
      'https://cdn.example.test/file.pdf?signature=abc',
    );
  });

  test('version query is replaced once and fragment is retained', () {
    final result = versionedDocumentUrl(
      '/api/mobile-documents/doc/content?token=a&preview_v=old#page=2',
      'new',
    );
    final uri = Uri.parse(result);
    expect(uri.queryParametersAll['preview_v'], ['new']);
    expect(uri.queryParameters['token'], 'a');
    expect(uri.fragment, 'page=2');
    expect(versionedDocumentUrl(result, 'new'), result);
  });

  test('external signed URL is unchanged even with an app-shaped path', () {
    const raw =
        'https://cdn.example.test/api/mobile-documents/id/content?signature=abc';
    expect(versionedDocumentUrl(raw, 'new'), raw);
  });

  test(
    'absolute app URL is versioned only with a matching valid API origin',
    () {
      final previous = AppConfig.apiBaseUrl;
      addTearDown(() => AppConfig.setApiBaseUrl(previous));
      const raw = 'https://app.example.test/api/mobile-documents/id/content';
      AppConfig.setApiBaseUrl('https://app.example.test');
      expect(versionedDocumentUrl(raw, 'new'), '$raw?preview_v=new');
      AppConfig.setApiBaseUrl('');
      expect(versionedDocumentUrl(raw, 'new'), raw);
      expect(
        versionedDocumentUrl(
          '//cdn.example.test/api/mobile-documents/id/content',
          'new',
        ),
        '//cdn.example.test/api/mobile-documents/id/content',
      );
    },
  );
}
