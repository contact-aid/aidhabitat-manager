import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/aggir_eligibility.dart';
import '../models/types.dart';
import 'document_repository.dart';

/// A normal offline document, so existing PDF ink, export and sync apply.
class AggirDocumentService {
  AggirDocumentService({DocumentRepository? repository})
    : _repository = repository ?? DocumentRepository();

  final DocumentRepository _repository;
  static final Map<String, Future<List<DocItem>>> _pending = {};

  static String documentId(String patientId) => 'doc_aggir_$patientId';

  Future<List<DocItem>> documentsFor(
    Dossier dossier, {
    bool createIfMissing = true,
  }) {
    if (!createIfMissing) return _load(dossier, createIfMissing: false);
    final key = dossier.patient.id;
    return _pending.putIfAbsent(key, () async {
      try {
        return await _load(dossier);
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<List<DocItem>> _load(
    Dossier dossier, {
    bool createIfMissing = true,
  }) async {
    final patient = dossier.patient;
    final docs = await _repository.fetchDocuments(patient.id);
    final id = documentId(patient.id);
    bool isAutomaticGrid(DocItem doc) =>
        doc.id == id ||
        (doc.title == 'Grille AGGIR' && doc.tags.contains('AGGIR'));
    final grids = docs.where(isAutomaticGrid).toList();
    if (!primaryBeneficiaryRequiresAggir(patient)) {
      // Hide the automatic grid without deleting handwriting or signatures.
      return docs.where((doc) => !isAutomaticGrid(doc)).toList();
    }
    // A remote alias can have a different local id from the deterministic
    // offline form. Keep one visible copy and never overwrite a signed one.
    if (grids.isNotEmpty) {
      final signed = grids.where(
        (doc) => (doc.annotationsJson ?? '').trim().isNotEmpty,
      );
      final preferred = signed.isNotEmpty
          ? signed.first
          : grids.firstWhere((doc) => doc.id == id, orElse: () => grids.first);
      return [preferred, ...docs.where((doc) => !isAutomaticGrid(doc))];
    }
    if (!createIfMissing) return docs;
    final bytes = await buildPdf(patient, today: DateTime.now());
    final document = await _repository.importDocumentBytes(
      patientId: patient.id,
      dossierId: dossier.id,
      localId: id,
      bytes: bytes,
      fileName: 'grille_aggir.pdf',
      title: 'Grille AGGIR',
      tags: const ['AGGIR'],
    );
    return [document, ...docs];
  }

  static Future<Uint8List> buildPdf(
    Patient patient, {
    required DateTime today,
  }) async {
    final background = await rootBundle.load(
      'assets/documents/grille_nationale_aggir.png',
    );
    final pdf = pw.Document();
    final font = pw.Font.ttf(
      await rootBundle.load('assets/documents/Inter-Medium.ttf'),
    );
    final image = pw.MemoryImage(background.buffer.asUint8List());
    pw.Widget field(
      String value,
      double left,
      double top,
      double width, {
      double height = 12,
    }) => pw.Positioned(
      left: left,
      top: top,
      child: pw.SizedBox(
        width: width,
        height: height,
        child: pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          alignment: pw.Alignment.centerLeft,
          child: pw.Text(
            value.trim().replaceAll(RegExp(r'\s+'), ' '),
            style: pw.TextStyle(font: font, fontSize: 10),
          ),
        ),
      ),
    );
    final date =
        '${today.day.toString().padLeft(2, '0')}/${today.month.toString().padLeft(2, '0')}/${today.year}';
    pdf.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(594, 846),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Stack(
          children: [
            pw.Positioned.fill(child: pw.Image(image, fit: pw.BoxFit.fill)),
            field(patient.lastName, 72, 92, 185),
            field(patient.firstName, 313, 93, 232),
            field(patient.address, 85, 139, 460),
            for (var i = 0; i < patient.zipCode.trim().length && i < 5; i++)
              field(patient.zipCode.trim()[i], 109 + i * 14.1, 163, 10),
            field(patient.city, 265, 164, 280),
            field(patient.city, 159, 683, 153),
            field(date, 337, 683, 98),
          ],
        ),
      ),
    );
    return pdf.save();
  }
}
