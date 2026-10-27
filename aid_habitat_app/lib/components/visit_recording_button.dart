import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';
import '../services/visit_assistant_service.dart';

class VisitRecordingButton extends StatelessWidget {
  const VisitRecordingButton({super.key, required this.dossier});
  final Dossier dossier;

  @override
  Widget build(BuildContext context) {
    if (!VisitAssistantConfig.enabled) return const SizedBox.shrink();
    final service = VisitAssistantService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final recording = service.recordingDossierId == dossier.id;
        final elsewhere = service.isRecording && !recording;
        final currentJobs = service.jobs
            .where((j) => j['dossierId'] == dossier.id)
            .toList();
        final latest = currentJobs.isEmpty ? null : currentJobs.first;
        final phase =
            (latest?['remote'] as Map?)?['status'] ?? latest?['status'];
        final status = switch (phase) {
          'pending' => 'En attente de connexion',
          'uploading' => 'Envoi de l’audio…',
          'transcribing' => 'Transcription en cours…',
          'reading_notes' => 'Lecture des notes…',
          'organizing' => 'Organisation des faits…',
          'drafting' => 'Rédaction en cours…',
          'complete' => 'Rédaction terminée',
          'recovery_required' => 'Audio à récupérer',
          _ => '',
        };
        final pending =
            latest != null &&
            latest['status'] != 'complete' &&
            latest['status'] != 'empty';
        final label = recording
            ? 'Arrêter l’enregistrement'
            : elsewhere
            ? 'Une autre visite est en cours d’enregistrement'
            : !VisitAssistantConfig.canRecord
            ? 'Enregistrement disponible dans l’application iPad de test'
            : pending
            ? 'Visite enregistrée, traitement en attente'
            : 'Enregistrer la visite';
        return Tooltip(
          message: label,
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: const Color(0xffe7e7e7)),
              boxShadow: const [
                BoxShadow(color: Color(0x08000000), blurRadius: 4),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!recording && status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      status,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff666666),
                      ),
                    ),
                  ),
                if (recording) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 27,
                    height: 20,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: service.voiceLevels.map((level) {
                        final amplitude = level <= 0.001
                            ? 0.0
                            : ((20 * math.log(level) / math.ln10 + 60) / 50)
                                  .clamp(0.0, 1.0);
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 100),
                          curve: Curves.easeOut,
                          width: 3.5,
                          height: 6 + 14 * amplitude,
                          decoration: BoxDecoration(
                            color: const Color(0xff7e8388),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${service.duration ~/ 60}:${(service.duration.toInt() % 60).toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff666666),
                    ),
                  ),
                ],
                IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  tooltip: label,
                  onPressed:
                      !VisitAssistantConfig.canRecord ||
                          elsewhere ||
                          service.isStarting
                      ? null
                      : () async {
                          try {
                            if (recording) {
                              await service.stop();
                            } else {
                              await service.start(dossier);
                            }
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    service.error ??
                                        'L’enregistrement reste conservé. Réessaie.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                  icon: service.isStarting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          recording ? Icons.stop_rounded : LucideIcons.mic,
                          size: recording ? 23 : 20,
                          color: elsewhere
                              ? Colors.grey
                              : const Color(0xff202326),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
