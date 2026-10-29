import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../components/brand_colors.dart';
import '../../components/notes_widget.dart';
import '../../components/note_panel_frame.dart';
import '../../components/notes_panel_title_banner.dart';
import '../../services/context_notes.dart';

/// A single written note survives subsection changes; handwriting stays scoped.
class ContextNotesPanel extends StatefulWidget {
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
  State<ContextNotesPanel> createState() => _ContextNotesPanelState();
}

class _ContextNotesPanelState extends State<ContextNotesPanel> {
  double _textFraction = 0.3;

  @override
  void didUpdateWidget(covariant ContextNotesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.patientId != widget.patientId) _textFraction = 0.3;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = math.max(0.0, constraints.maxHeight - 8);
        final minTextHeight = math.min(100.0, availableHeight * 0.4);
        final maxTextHeight = math.max(minTextHeight, availableHeight - 144);
        final textHeight = (availableHeight * _textFraction)
            .clamp(minTextHeight, maxTextHeight)
            .toDouble();
        final splitter = Semantics(
          label: 'Redimensionner le texte et les notes manuscrites',
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeRow,
            child: GestureDetector(
              key: const ValueKey('context-notes-splitter'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                if (availableHeight <= 0) return;
                final currentHeight = (availableHeight * _textFraction).clamp(
                  minTextHeight,
                  maxTextHeight,
                );
                final nextHeight = (currentHeight + details.delta.dy).clamp(
                  minTextHeight,
                  maxTextHeight,
                );
                setState(() => _textFraction = nextHeight / availableHeight);
              },
              child: Container(
                height: 22,
                width: double.infinity,
                color: const Color(0xFFEDE8F5),
                alignment: Alignment.center,
                child: const Icon(
                  LucideIcons.chevronsDown,
                  size: 16,
                  color: kBrandPurple,
                ),
              ),
            ),
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: textHeight,
              child: NotePanelFrame(
                header: const NotesPanelTitleBanner(
                  title: 'Habitudes de vie',
                  borderless: true,
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: NotesWidget(
                        key: ValueKey('${widget.patientId}::$habitsTextTabKey'),
                        patientId: widget.patientId,
                        dossierId: widget.dossierId,
                        tabKey: habitsTextTabKey,
                        liveText: widget.liveText,
                        externalRefreshToken: widget.externalRefreshToken,
                        onDraftChange: widget.onTextDraft,
                        onExpandToTab: widget.onExpandText,
                        showCanvas: false,
                        allowPagination: false,
                        maxPages: 1,
                        sharedText: true,
                        showSaveButton: false,
                        fillParentHeight: true,
                        placeholder: '',
                        attachedToTitleBanner: true,
                        borderlessTextEditor: true,
                      ),
                    ),
                    splitter,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final medical in [true, false])
                    Offstage(
                      offstage: medical != widget.isMedical,
                      child: NotesWidget(
                        key: ValueKey(
                          '${widget.patientId}::${medical ? medicalDrawingTabKey : autonomyDrawingTabKey}',
                        ),
                        patientId: widget.patientId,
                        dossierId: widget.dossierId,
                        tabKey: medical
                            ? medicalDrawingTabKey
                            : autonomyDrawingTabKey,
                        title: medical ? 'Médical' : 'Autonomie',
                        externalRefreshToken: widget.externalRefreshToken,
                        showText: false,
                        allowTextModal: false,
                        showSaveButton: false,
                        fillParentHeight: true,
                        stackedCards: true,
                        medicalFlags: medical ? widget.medicalFlags : null,
                        medicalFlagsScopeKey: medical
                            ? widget.medicalFlagsScopeKey
                            : null,
                        medicalFlagsUserEditRevision:
                            widget.medicalFlagsUserEditRevision,
                        onMedicalFlagsChanged: medical
                            ? widget.onMedicalFlagsChanged
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
