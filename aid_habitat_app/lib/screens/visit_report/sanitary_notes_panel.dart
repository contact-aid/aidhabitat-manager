import 'package:flutter/material.dart';

import '../../components/notes_widget.dart';
import '../../components/notes_panel_title_banner.dart';
import '../../services/sanitary_notes.dart';

/// One keyboard observation, with independently paginated room drawings.
class SanitaryNotesPanel extends StatelessWidget {
  const SanitaryNotesPanel({
    super.key,
    required this.patientId,
    required this.isBathroom,
    this.liveText,
    this.externalRefreshToken = 0,
    this.onTextDraft,
    this.onExpandText,
  });

  final String patientId;
  final bool isBathroom;
  final String? liveText;
  final int externalRefreshToken;
  final ValueChanged<NoteDraftPayload>? onTextDraft;
  final VoidCallback? onExpandText;

  @override
  Widget build(BuildContext context) {
    final drawingKey = isBathroom ? bathroomDrawingTabKey : wcDrawingTabKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotesPanelTitleBanner(
          title: 'Observations sur les équipements et utilisations',
          attachedToBelow: true,
        ),
        Expanded(
          flex: 3,
          child: NotesWidget(
            key: ValueKey('$patientId::$sanitaryTextTabKey'),
            patientId: patientId,
            tabKey: sanitaryTextTabKey,
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
          child: NotesWidget(
            key: ValueKey('$patientId::$drawingKey'),
            patientId: patientId,
            tabKey: drawingKey,
            title: isBathroom ? 'Salle de bain' : 'WC',
            externalRefreshToken: externalRefreshToken,
            showText: false,
            allowTextModal: false,
            showSaveButton: false,
            fillParentHeight: true,
            stackedCards: true,
          ),
        ),
      ],
    );
  }
}
