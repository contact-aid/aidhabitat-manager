import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/types.dart';
import 'document_repository.dart';

/// Creates the ANAH mandate as an ordinary offline document in Documents.
class MandateDocumentService {
  MandateDocumentService({DocumentRepository? repository})
    : _repository = repository ?? DocumentRepository();

  final DocumentRepository _repository;
  static final Map<String, Future<List<DocItem>>> _pending = {};

  static bool isRequested(Dossier dossier) {
    try {
      final value = jsonDecode(dossier.compteAnah);
      return value is Map &&
          value['mandat'] == 'Oui' &&
          value['mandatPar'] == "Aid'habitat";
    } catch (_) {
      return false;
    }
  }

  static String templateFor(LocalAppUser user) {
    switch (user.email.trim().toLowerCase()) {
      case 'c.demenais@aidhabitat.fr':
        return 'mandat_coralie';
      case 'c.jeuland@aidhabitat.fr':
        return 'mandat_christelle';
      default:
        return 'mandat_administratif';
    }
  }

  static String documentId(Dossier dossier, LocalAppUser user) =>
      'doc_mandat_${dossier.id}_${user.id}';

  Future<List<DocItem>> documentsFor(
    Dossier dossier,
    LocalAppUser? user, {
    bool createIfMissing = true,
  }) async {
    if (user == null ||
        user.role == LocalUserRole.admin ||
        !isRequested(dossier)) {
      return _repository.fetchDocuments(dossier.patient.id);
    }
    if (!createIfMissing) return _load(dossier, user, createIfMissing: false);
    final key = documentId(dossier, user);
    return _pending.putIfAbsent(key, () async {
      try {
        return await _load(dossier, user);
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<List<DocItem>> _load(
    Dossier dossier,
    LocalAppUser user, {
    bool createIfMissing = true,
  }) async {
    final docs = await _repository.fetchDocuments(dossier.patient.id);
    final id = documentId(dossier, user);
    final dossierTag = 'Dossier:${dossier.id}';
    final accountTag = 'Compte:${user.id}';
    if (docs.any(
          (doc) =>
              doc.id == id ||
              (doc.tags.contains('Mandat automatique') &&
                  doc.tags.contains(dossierTag) &&
                  doc.tags.contains(accountTag)),
        ) ||
        !createIfMissing) {
      return docs;
    }

    final bytes = await buildPdf(dossier.patient, user);
    final document = await _repository.importDocumentBytes(
      patientId: dossier.patient.id,
      dossierId: dossier.id,
      localId: id,
      bytes: bytes,
      fileName: 'mandat_administratif.pdf',
      title: 'Mandat administratif - ${user.shortDisplayName}',
      tags: ['Mandat', 'Mandat automatique', dossierTag, accountTag],
    );
    return [document, ...docs];
  }

  static String _dateOfBirth(String raw) {
    final value = raw.trim();
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(value);
    if (iso != null) return '${iso[3]}/${iso[2]}/${iso[1]}';
    return value;
  }

  static Future<Uint8List> buildPdf(Patient patient, LocalAppUser user) async {
    final template = templateFor(user);
    final pdf = pw.Document();
    final font = pw.Font.ttf(
      await rootBundle.load('assets/documents/Inter-Medium.ttf'),
    );
    final nameParts = user.displayName.trim().split(RegExp(r'\s+'));
    final intervenantFirst = nameParts.isEmpty ? '' : nameParts.first;
    final intervenantLast = nameParts.length > 1
        ? nameParts.skip(1).join(' ')
        : '';

    pw.Widget field(String value, double left, double top, double width) =>
        pw.Positioned(
          left: left,
          top: top,
          child: pw.SizedBox(
            width: width,
            height: 12,
            child: pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              alignment: pw.Alignment.centerLeft,
              child: pw.Text(
                value.trim().replaceAll(RegExp(r'\s+'), ' '),
                style: pw.TextStyle(font: font, fontSize: 9),
              ),
            ),
          ),
        );

    final address = [
      patient.address.trim(),
      '${patient.zipCode.trim()} ${patient.city.trim()}'.trim(),
    ].where((part) => part.isNotEmpty).join(', ');
    for (var page = 1; page <= 2; page++) {
      final background = await rootBundle.load(
        'assets/documents/$template-$page.png',
      );
      final image = pw.MemoryImage(background.buffer.asUint8List());
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Stack(
            children: [
              pw.Positioned.fill(child: pw.Image(image, fit: pw.BoxFit.fill)),
              if (page == 1) ...[
                field(patient.lastName, 79, 231, 213),
                field(patient.firstName, 332, 231, 212),
                if (patient.birthDate.trim().isNotEmpty)
                  field(
                    'Né(e) le ${_dateOfBirth(patient.birthDate)}',
                    265,
                    194,
                    230,
                  ),
                if (patient.occupationStatus.trim().toLowerCase().contains(
                  'propri',
                ))
                  field('X', 55, 249, 10),
                field(address, 55, 282, 490),
                field(patient.email, 76, 312, 194),
                field(patient.phone, 365, 312, 179),
                if (template == 'mandat_administratif') ...[
                  field(intervenantLast, 79, 375, 214),
                  field(intervenantFirst, 331, 375, 213),
                  field("Aid'habitat", 202, 396, 342),
                  field(
                    '16 rue Léo Lagrange, 35131 Chartres-de-Bretagne',
                    134,
                    414,
                    410,
                  ),
                  field(user.email, 76, 448, 195),
                ],
              ],
            ],
          ),
        ),
      );
    }
    return pdf.save();
  }
}
