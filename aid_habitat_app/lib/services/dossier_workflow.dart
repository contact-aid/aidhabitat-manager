import '../models/types.dart';
import 'visit_date_time.dart';

enum DossierBucket { visiteAFaire, rapportAFaire, rapportEnvoye }

bool isDossierVisitInPast(Dossier dossier, {DateTime? now}) {
  final visit = parseVisitDateTime(dossier.visitDate);
  if (visit == null) return false;
  final today = parseVisitDateTime(
    (now ?? DateTime.now()).toUtc().toIso8601String(),
  )!;
  return DateTime.utc(
    visit.year,
    visit.month,
    visit.day,
  ).isBefore(DateTime.utc(today.year, today.month, today.day));
}

DossierBucket? dossierBucket(Dossier dossier, {DateTime? now}) {
  final past = isDossierVisitInPast(dossier, now: now);
  final visit = parseVisitDateTime(dossier.visitDate);
  final stage = dossier.airtableStage?.trim().toLowerCase();
  if (stage != null) {
    if (stage == 'annulé') return null;
    final scheduledStage = RegExp(r'^1[ab](?:\b|\.)').hasMatch(stage);
    final sent = parseVisitDateTime(dossier.airtableReportSentDate);
    final previousReport =
        scheduledStage &&
        visit != null &&
        sent != null &&
        DateTime.utc(
          sent.year,
          sent.month,
          sent.day,
        ).isBefore(DateTime.utc(visit.year, visit.month, visit.day));
    if (sent != null && !previousReport) {
      return DossierBucket.rapportEnvoye;
    }
    if (visit == null) return null;
    if (past) return DossierBucket.rapportAFaire;
    return scheduledStage ? DossierBucket.visiteAFaire : null;
  }
  if (dossier.status.index >= DossierStatus.IN_PROGRESS.index) {
    return DossierBucket.rapportEnvoye;
  }
  if (visit == null) return null;
  return past ? DossierBucket.rapportAFaire : DossierBucket.visiteAFaire;
}
