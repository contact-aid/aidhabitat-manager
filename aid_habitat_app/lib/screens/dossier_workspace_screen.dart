import 'package:flutter/material.dart';
import '../components/retained_space_switcher.dart';
import '../models/types.dart';
import 'documents_screen.dart';
import 'visit_report_screen.dart';

/// The two spaces share one navigation entry and remain inside the sidebar shell.
class DossierWorkspaceScreen extends StatefulWidget {
  final Dossier dossier;
  final bool initialDocuments;
  final VoidCallback onBack;
  final void Function(bool documents, Dossier dossier)? onSpaceChanged;
  final ValueChanged<String>? onContextChanged;
  final int conflictRefreshToken;
  final int housingConflictRefreshToken;
  final int contextConflictRefreshToken;
  final int patientConflictRefreshToken;

  const DossierWorkspaceScreen({
    super.key,
    required this.dossier,
    required this.onBack,
    this.initialDocuments = false,
    this.onSpaceChanged,
    this.onContextChanged,
    this.conflictRefreshToken = 0,
    this.housingConflictRefreshToken = 0,
    this.contextConflictRefreshToken = 0,
    this.patientConflictRefreshToken = 0,
  });

  @override
  State<DossierWorkspaceScreen> createState() => _DossierWorkspaceScreenState();
}

class _DossierWorkspaceScreenState extends State<DossierWorkspaceScreen> {
  late bool _documents = widget.initialDocuments;
  late Dossier _dossier = widget.dossier;

  @override
  void didUpdateWidget(covariant DossierWorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.dossier != oldWidget.dossier) _dossier = widget.dossier;
    if (widget.initialDocuments != oldWidget.initialDocuments) {
      _documents = widget.initialDocuments;
    }
  }

  void _switchSpace(bool documents, Dossier dossier) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _documents = documents;
      _dossier = dossier;
    });
    widget.onSpaceChanged?.call(documents, dossier);
  }

  @override
  Widget build(BuildContext context) => RetainedSpaceSwitcher(
    key: ValueKey(_dossier.id),
    showSecond: _documents,
    firstBuilder: (_) => VisitReportScreen(
      dossier: _dossier,
      onBack: widget.onBack,
      onOpenDocuments: (dossier) => _switchSpace(true, dossier),
      onContextChanged: widget.onContextChanged,
      conflictRefreshToken: widget.conflictRefreshToken,
      housingConflictRefreshToken: widget.housingConflictRefreshToken,
      contextConflictRefreshToken: widget.contextConflictRefreshToken,
      patientConflictRefreshToken: widget.patientConflictRefreshToken,
    ),
    secondBuilder: (_) => DocumentsScreen(
      dossier: _dossier,
      onBack: widget.onBack,
      onOpenVisitReport: () => _switchSpace(false, _dossier),
    ),
  );
}
