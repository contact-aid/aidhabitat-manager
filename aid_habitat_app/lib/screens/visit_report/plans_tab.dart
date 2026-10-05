import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../components/plan_canvas.dart';
import '../../components/soft_transitions.dart';
import '../../models/types.dart';
import '../../models/visit_report_categories.dart';
import '../../services/data_service.dart';
import '../../services/note_repository.dart';

/// Plans tab — React-parity multi-page canvas:
///  - Pagination bar with Previous / Next / Add / Delete
///  - Each page persists its own strokes under the same `tabKey='Plans'`
///    discriminated by `pageNumber`
///  - Each page can be tagged "Avant travaux" / "Après travaux" /
///    via le pill flottant en haut-centre. La valeur est
///    persistée dans `note_pages.plan_phase` (cf. v11→v12 migration)
///    et alimente les pages 9 (avant) / 10 (après) du rapport PDF.
class PlansTab extends StatefulWidget {
  final Dossier dossier;
  final DataService? dataService;
  final Future<String?> Function()? previewDataUrlBuilder;

  const PlansTab({
    super.key,
    required this.dossier,
    this.dataService,
    this.previewDataUrlBuilder,
  });

  @override
  State<PlansTab> createState() => _PlansTabState();
}

class _PlansTabState extends State<PlansTab> {
  static const String _kTabKey = 'Plans';
  static const String _kEmptyPlanDrawingJson =
      '{"format":"plan_canvas_v1","strokes":[]}';
  static const String _kBlankPlanDrawingJson =
      '{"format":"plan_canvas_v1","pageKind":"blank","strokes":[]}';

  late final DataService _dataService = widget.dataService ?? DataService();
  final PlanCanvasController _planCanvasController = PlanCanvasController();
  int _currentPage = 0;
  final List<int> _pageNumbers = [0];
  int get _totalPages => _pageNumbers.length;
  int get _currentPageNumber => _pageNumbers[_currentPage];
  int _nextPageNumber = 1;
  bool _probed = false;
  final Map<int, LocalNotePageSnapshot> _protectedPages = {};

  /// Phase de la page courante (avant / après / null). Mise à jour à
  /// chaque navigation via [_loadPhaseForCurrentPage].
  PlanPhase? _currentPhase = PlanPhase.avant;

  /// Cache local des phases déjà fetched pour éviter un round-trip
  /// SQLite à chaque changement de page. Invalidé lors d'un setPhase.
  final Map<int, PlanPhase?> _phaseCache = {};
  final Map<int, bool> _blankPages = {};
  int? _newPageNeedingPreview;
  bool _creatingPage = false;

  @override
  void initState() {
    super.initState();
    _probeInitialPages();
  }

  /// Read every saved identity. Gaps never hide later pages or renumber them.
  Future<void> _probeInitialPages() async {
    final pages = await _dataService.fetchLocalNotePages(
      patientId: widget.dossier.patient.id,
      dossierId: widget.dossier.id,
      tabKey: _kTabKey,
    );
    if (!mounted) return;
    final numbers = <int>{0};
    for (final page in pages) {
      if (page.pageNumber >= _nextPageNumber) {
        _nextPageNumber = page.pageNumber + 1;
      }
      if (page.drawingJson.isEmpty &&
          page.textContent.isEmpty &&
          page.previewDataUrl == null &&
          page.remoteUrl == null) {
        continue;
      }
      numbers.add(page.pageNumber);
      if (!isEditablePlanDrawing(page.drawingJson)) {
        _protectedPages[page.pageNumber] = page;
      }
      _blankPages[page.pageNumber] = _isBlankPage(page.drawingJson);
      _phaseCache[page.pageNumber] = page.planPhase;
    }
    setState(() {
      _pageNumbers
        ..clear()
        ..addAll(numbers.toList()..sort());
      _probed = true;
    });
    _loadPhaseForCurrentPage();
  }

  void _goToPage(int page) {
    if (_creatingPage || page < 0 || page >= _totalPages) return;
    setState(() {
      if (page != _currentPage) _newPageNeedingPreview = null;
      _currentPage = page;
    });
    _loadPhaseForCurrentPage();
  }

  Future<void> _addPage({required bool blank, bool duplicate = false}) async {
    if (_creatingPage) return;
    if (!blank && !duplicate && _protectedPages.containsKey(0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Le plan avant travaux est une image ancienne. Dupliquez cette page pour la conserver, ou ajoutez une page vide.',
          ),
        ),
      );
      return;
    }
    setState(() => _creatingPage = true);
    try {
      await _planCanvasController.flush();
      final sourcePage = _currentPageNumber;
      final sourceJson = duplicate
          ? await _dataService.fetchNoteDrawingJson(
              patientId: widget.dossier.patient.id,
              tabKey: _kTabKey,
              pageNumber: sourcePage,
            )
          : blank
          ? _kBlankPlanDrawingJson
          : await _drawingJsonForNewScenario();
      final isBlank = duplicate ? _isBlankPage(sourceJson) : blank;
      final phase = isBlank
          ? null
          : duplicate
          ? _currentPhase
          : PlanPhase.apres;
      final int newIndex;
      if (duplicate) {
        newIndex = await _dataService.duplicateLocalNotePage(
          patientId: widget.dossier.patient.id,
          dossierId: widget.dossier.id,
          tabKey: _kTabKey,
          sourcePageNumber: sourcePage,
          previewDataUrl: _protectedPages.containsKey(sourcePage)
              ? null
              : await _planCanvasController.previewDataUrl(
                  patientId: widget.dossier.patient.id,
                  tabKey: _kTabKey,
                  pageNumber: sourcePage,
                ),
        );
      } else {
        newIndex = _nextPageNumber;
        await _dataService.saveNoteDrawingJson(
          patientId: widget.dossier.patient.id,
          dossierId: widget.dossier.id,
          tabKey: _kTabKey,
          pageNumber: newIndex,
          drawingJson: sourceJson ?? _kEmptyPlanDrawingJson,
          mutationOrigin: SyncMutationOrigin.userEdit,
        );
        await _dataService.setNotePlanPhase(
          patientId: widget.dossier.patient.id,
          tabKey: _kTabKey,
          pageNumber: newIndex,
          phase: phase,
        );
      }
      if (!mounted) return;
      setState(() {
        _pageNumbers.add(newIndex);
        if (duplicate && _protectedPages.containsKey(sourcePage)) {
          _protectedPages[newIndex] = _protectedPages[sourcePage]!;
        }
        _nextPageNumber = newIndex + 1;
        _currentPage = _pageNumbers.length - 1;
        _currentPhase = phase;
        _phaseCache[newIndex] = phase;
        _blankPages[newIndex] = isBlank;
        _newPageNeedingPreview = isBlank || duplicate ? null : newIndex;
        _creatingPage = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _creatingPage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('La page n’a pas pu être créée.')),
        );
      }
    }
  }

  /// Charge la phase de la page courante depuis le cache (instantané)
  /// ou SQLite (1 lecture). Met à jour `_currentPhase` côté UI dès que
  /// disponible — le pill se rafraîchit automatiquement.
  Future<void> _loadPhaseForCurrentPage() async {
    final page = _currentPageNumber;
    if (page == 0) {
      _phaseCache[page] = PlanPhase.avant;
      if (!mounted) return;
      setState(() => _currentPhase = PlanPhase.avant);
      return;
    }
    if (_blankPages[page] == true) {
      _phaseCache[page] = null;
      if (mounted) setState(() => _currentPhase = null);
      return;
    }
    if (_phaseCache.containsKey(page)) {
      if (!mounted) return;
      setState(() => _currentPhase = _phaseCache[page]);
      return;
    }
    final persistedPhase = await _dataService.fetchNotePlanPhase(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: page,
    );
    final phase = persistedPhase ?? PlanPhase.apres;
    _phaseCache[page] = phase;
    if (!mounted || page != _currentPageNumber) return;
    setState(() => _currentPhase = phase);
  }

  Widget _buildProtectedPage(LocalNotePageSnapshot page) {
    Widget preview = const Center(
      child: Text(
        'Aperçu indisponible hors ligne. Le plan enregistré est conservé.',
      ),
    );
    final dataUrl = page.previewDataUrl;
    try {
      if (dataUrl != null && dataUrl.startsWith('data:image/')) {
        preview = Image.memory(
          base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1)),
          fit: BoxFit.contain,
        );
      } else if (page.remoteUrl != null && page.remoteUrl!.isNotEmpty) {
        preview = Image.network(
          page.remoteUrl!,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Center(
            child: Text(
              'Aperçu indisponible. Le plan enregistré est conservé.',
            ),
          ),
        );
      }
    } catch (_) {
      /* Keep the saved image intact when its preview cannot load. */
    }
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          const Text('Plan ancien conservé en lecture seule'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _creatingPage
                ? null
                : () => _addPage(blank: false, duplicate: true),
            icon: const Icon(Icons.copy),
            label: const Text('Dupliquer cette page'),
          ),
          Expanded(
            child: InteractiveViewer(child: Center(child: preview)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Pagination et outils sont fusionnés dans la toolbar flottante du canvas.
    // On wrap le canvas dans un Stack pour y faire flotter le toggle « Phase »
    // hors de la zone d'outils.
    if (!_probed) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Positioned.fill(
          child: _PlanCanvasPhaseSwitcher(
            pageIndex: _currentPage,
            phase: _currentPhase,
            child: _protectedPages.containsKey(_currentPageNumber)
                ? _buildProtectedPage(_protectedPages[_currentPageNumber]!)
                : PlanCanvas(
                    key: ValueKey(
                      'plans-${widget.dossier.patient.id}-$_currentPageNumber',
                    ),
                    patientId: widget.dossier.patient.id,
                    controller: _planCanvasController,
                    tabKey: _kTabKey,
                    pageNumber: _currentPageNumber,
                    refreshPreviewOnLoad:
                        _newPageNeedingPreview == _currentPageNumber,
                    independentPage: _blankPages[_currentPageNumber] ?? false,
                    dataService: widget.dataService,
                    previewDataUrlBuilder: widget.previewDataUrlBuilder,
                    currentPage: _currentPage,
                    totalPages: _totalPages,
                    onPrevPage: () => _selectScenarioPage(_currentPage - 1),
                    onNextPage: () => _selectScenarioPage(_currentPage + 1),
                    onAddPage: _creatingPage
                        ? null
                        : () => _addPage(blank: true),
                    onDuplicatePage: _creatingPage
                        ? null
                        : () => _addPage(blank: false, duplicate: true),
                    // Deletion needs the reversible tombstone contract; never shift IDs.
                    onDeletePage: null,
                    deletionUnavailableReason: _currentPage == 0
                        ? null
                        : 'Suppression indisponible pour préserver les plans enregistrés.',
                  ),
          ),
        ),
        // Sélecteur de scénarios : page 1 = plan avant travaux, pages
        // suivantes = scénarios des travaux préconisés.
        Positioned(
          // La palette d'équipements occupe le coin haut-gauche dans le
          // canvas. On décale donc les scénarios à sa droite pour éviter
          // toute superposition.
          left: 380,
          right: 252,
          top: 16,
          child: Align(
            alignment: Alignment.topLeft,
            child: _ScenarioTabs(
              currentPage: _currentPage,
              totalPages: _totalPages,
              onSelect: _selectScenarioPage,
              labels: [for (var i = 0; i < _totalPages; i++) _pageLabel(i)],
              nextScenarioNumber: _nextScenarioNumber,
              onAddBlank: _creatingPage ? null : () => _addPage(blank: true),
              onAddScenario: _creatingPage
                  ? null
                  : () => _addPage(blank: false),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _selectScenarioPage(int page) async {
    if (page == _currentPage) return;
    await _planCanvasController.flush();
    _goToPage(page);
  }

  Future<String> _drawingJsonForNewScenario() async {
    // Chaque scénario repart du plan avant travaux. Copier le scénario
    // précédent rendait le scénario 2 vide lorsque sa sauvegarde n'avait
    // pas encore été matérialisée, et propageait aussi ses préconisations.
    const sourcePage = 0;
    final source = await _dataService.fetchNoteDrawingJson(
      patientId: widget.dossier.patient.id,
      tabKey: _kTabKey,
      pageNumber: sourcePage,
    );
    return _isEmptyPlanDrawingJson(source) ? _kEmptyPlanDrawingJson : source!;
  }

  int get _nextScenarioNumber =>
      1 +
      List.generate(
        _totalPages - 1,
        (index) => index + 1,
      ).where((index) => _blankPages[_pageNumbers[index]] != true).length;

  String _pageLabel(int pageIndex) {
    if (pageIndex == 0) return 'Plan avant travaux';
    var scenarioNumber = 0;
    var blankNumber = 0;
    for (var i = 1; i <= pageIndex; i++) {
      if (_blankPages[_pageNumbers[i]] == true) {
        blankNumber++;
      } else {
        scenarioNumber++;
      }
    }
    return _blankPages[_pageNumbers[pageIndex]] == true
        ? 'Page libre $blankNumber'
        : 'Scénario $scenarioNumber';
  }

  bool _isBlankPage(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)['pageKind'] == 'blank';
    } catch (_) {
      return false;
    }
  }

  bool _isEmptyPlanDrawingJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return true;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['format'] != 'plan_canvas_v1') return false;
      final strokes = decoded['strokes'];
      return strokes is! List || strokes.isEmpty;
    } catch (_) {
      return false;
    }
  }
}

class _PlanCanvasPhaseSwitcher extends StatefulWidget {
  const _PlanCanvasPhaseSwitcher({
    required this.pageIndex,
    required this.phase,
    required this.child,
  });

  final int pageIndex;
  final PlanPhase? phase;
  final Widget child;

  @override
  State<_PlanCanvasPhaseSwitcher> createState() =>
      _PlanCanvasPhaseSwitcherState();
}

class _PlanCanvasPhaseSwitcherState extends State<_PlanCanvasPhaseSwitcher> {
  int _direction = 1;

  int _phaseRank(PlanPhase? phase, int pageIndex) {
    switch (phase) {
      case PlanPhase.avant:
        return 0;
      case PlanPhase.apres:
        return 1;
      case null:
        return pageIndex;
    }
  }

  @override
  void didUpdateWidget(covariant _PlanCanvasPhaseSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageIndex == oldWidget.pageIndex &&
        widget.phase == oldWidget.phase) {
      return;
    }
    final oldRank = _phaseRank(oldWidget.phase, oldWidget.pageIndex);
    final newRank = _phaseRank(widget.phase, widget.pageIndex);
    if (oldRank != newRank) {
      _direction = newRank > oldRank ? 1 : -1;
    } else {
      _direction = widget.pageIndex >= oldWidget.pageIndex ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentKey = ValueKey<int>(widget.pageIndex);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      reverseDuration: kSoftMedium,
      switchInCurve: kSoftCurve,
      switchOutCurve: kSoftCurveIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, if (currentChild != null) currentChild],
      ),
      transitionBuilder: (child, animation) {
        final isIncoming = child.key == currentKey;
        final direction = _direction.toDouble();
        final slideBegin = isIncoming
            ? Offset(0.08 * direction, 0)
            : Offset(-0.05 * direction, 0);
        const scaleBegin = 0.985;
        const scaleEnd = 1.0;
        final curved = CurvedAnimation(
          parent: animation,
          curve: isIncoming ? kSoftCurve : kSoftCurveIn,
        );

        return ClipRect(
          child: FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: slideBegin,
                end: Offset.zero,
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(
                  begin: scaleBegin,
                  end: scaleEnd,
                ).animate(curved),
                child: child,
              ),
            ),
          ),
        );
      },
      child: KeyedSubtree(key: currentKey, child: widget.child),
    );
  }
}

// ---------------------------------------------------------------------------
// Sélecteur de scénarios — page 1 = avant travaux, pages suivantes = scénarios
// ---------------------------------------------------------------------------

class _ScenarioTabs extends StatelessWidget {
  final int currentPage;
  final int totalPages;
  final List<String> labels;
  final int nextScenarioNumber;
  final ValueChanged<int> onSelect;
  final VoidCallback? onAddBlank;
  final VoidCallback? onAddScenario;

  const _ScenarioTabs({
    required this.currentPage,
    required this.totalPages,
    required this.labels,
    required this.nextScenarioNumber,
    required this.onSelect,
    required this.onAddBlank,
    required this.onAddScenario,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < totalPages; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _ScenarioChip(
                label: labels[i],
                selected: currentPage == i,
                onTap: () => onSelect(i),
              ),
            ],
            const SizedBox(width: 6),
            PopupMenuButton<String>(
              tooltip: 'Ajouter une page',
              enabled: onAddBlank != null && onAddScenario != null,
              icon: const Icon(LucideIcons.plus, size: 18),
              color: Colors.white,
              onSelected: (value) {
                if (value == 'blank') onAddBlank?.call();
                if (value == 'scenario') onAddScenario?.call();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'blank',
                  child: Text('Page vide indépendante'),
                ),
                PopupMenuItem(
                  value: 'scenario',
                  child: Text('Scénario $nextScenarioNumber'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScenarioChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ScenarioChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? const Color(0xFF554265) : const Color(0xFF2B323A);
    final bg = selected ? const Color(0xFFF2ECF5) : Colors.transparent;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? const Color(0xFF8E6AA3).withValues(alpha: 0.28)
                  : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
