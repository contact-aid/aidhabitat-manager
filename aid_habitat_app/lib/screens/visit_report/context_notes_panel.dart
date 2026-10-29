import 'package:flutter/material.dart';
import '../../components/notes_widget.dart';
import '../../components/notes_panel_title_banner.dart';
import '../../services/context_notes.dart';

/// A single written note survives subsection changes; handwriting stays scoped.
class ContextNotesPanel extends StatelessWidget {
  const ContextNotesPanel({
    super.key,
    required this.patientId,
    this.dossierId,
    required this.isMedical,
    this.liveText,
    this.externalRefreshToken = 0,
    this.onTextDraft,
    this.onExpandText,
    this.medicalFlags,
    this.medicalFlagsScopeKey,
    this.medicalFlagsUserEditRevision = 0,
    this.onMedicalFlagsChanged,
  });
  final String patientId;
  final String? dossierId;
  final bool isMedical;
  final String? liveText;
  final int externalRefreshToken;
  final ValueChanged<NoteDraftPayload>? onTextDraft;
  final VoidCallback? onExpandText;
  final Set<int>? medicalFlags;
  final String? medicalFlagsScopeKey;
  final int medicalFlagsUserEditRevision;
  final ValueChanged<Set<int>>? onMedicalFlagsChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotesPanelTitleBanner(
          title: 'Habitudes de vie',
          attachedToBelow: true,
        ),
        Expanded(
          flex: 3,
          child: NotesWidget(
            key: ValueKey('$patientId::$habitsTextTabKey'),
            patientId: patientId,
            dossierId: dossierId,
            tabKey: habitsTextTabKey,
            liveText: liveText,
            externalRefreshToken: externalRefreshToken,
            onDraftChange: onTextDraft,
            onExpandToTab: onExpandText,
            showCanvas: false,
            allowPagination: false,
            maxPages: 1,
            sharedText: true,
            showSaveButton: false,
            fillParentHeight: true,
            placeholder: '',
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          flex: 7,
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final medical in [true, false])
                Offstage(
                  offstage: medical != isMedical,
                  child: NotesWidget(
                    key: ValueKey(
                      '$patientId::${medical ? medicalDrawingTabKey : autonomyDrawingTabKey}',
                    ),
                    patientId: patientId,
                    dossierId: dossierId,
                    tabKey: medical
                        ? medicalDrawingTabKey
                        : autonomyDrawingTabKey,
                    title: medical ? 'Médical' : 'Autonomie',
                    externalRefreshToken: externalRefreshToken,
                    showText: false,
                    allowTextModal: false,
                    showSaveButton: false,
                    fillParentHeight: true,
                    stackedCards: true,
                    medicalFlags: medical ? medicalFlags : null,
                    medicalFlagsScopeKey: medical ? medicalFlagsScopeKey : null,
                    medicalFlagsUserEditRevision: medicalFlagsUserEditRevision,
                    onMedicalFlagsChanged: medical
                        ? onMedicalFlagsChanged
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
