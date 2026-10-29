import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/visit_assistant_service.dart';
import '../../components/visit_transcript_workspace.dart';

class VisitTranscriptTab extends StatefulWidget {
  const VisitTranscriptTab({super.key, required this.dossierId});
  final String dossierId;
  @override
  State<VisitTranscriptTab> createState() => _VisitTranscriptTabState();
}

class _VisitTranscriptTabState extends State<VisitTranscriptTab> {
  final _service = VisitAssistantService.instance;
  List<Map<String, dynamic>> _jobs = [];
  String? _selected, _error, _lastProgress;
  bool _loading = true, _refreshing = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _service.addListener(_progress);
    unawaited(_load());
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_jobs.any((j) => !['complete', 'failed'].contains(j['status']))) {
        unawaited(_load());
      }
    });
  }

  @override
  void didUpdateWidget(covariant VisitTranscriptTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dossierId != widget.dossierId) {
      _jobs = [];
      _selected = null;
      _loading = true;
      unawaited(_load());
    }
  }

  void _progress() {
    final progress = _service.jobs
        .where((j) => j['dossierId'] == widget.dossierId)
        .map(
          (j) =>
              '${j['id']}:${j['status']}:${(j['remote'] as Map?)?['status']}:${((j['remote'] as Map?)?['transcript'] as List?)?.length}',
        )
        .join();
    if (progress == _lastProgress) return;
    _lastProgress = progress;
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_refreshing) return;
    _refreshing = true;
    final dossier = widget.dossierId;
    try {
      final jobs = await _service.loadTranscripts(dossier);
      if (!mounted || dossier != widget.dossierId) return;
      setState(() {
        _jobs = jobs;
        if (!jobs.any((j) => j['id'] == _selected)) {
          _selected = jobs.firstOrNull?['id'] as String?;
        }
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted && dossier == widget.dossierId) {
        setState(() {
          _loading = false;
          _error = 'Connexion indisponible. Réessaie dans un instant.';
        });
      }
    } finally {
      _refreshing = false;
      if (mounted && dossier != widget.dossierId) unawaited(_load());
    }
  }

  @override
  void dispose() {
    _service.removeListener(_progress);
    _refreshTimer?.cancel();
    super.dispose();
  }

  String _visitLabel(Map<String, dynamic> job) {
    final date = DateTime.tryParse('${job['createdAt']}')?.toLocal();
    final day = date == null
        ? 'Visite'
        : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} à ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    final minutes = ((job['audioDurationSeconds'] as num? ?? 0) / 60).ceil();
    return '$day · $minutes min';
  }

  @override
  Widget build(BuildContext context) {
    final job = _jobs.where((j) => j['id'] == _selected).firstOrNull;
    final failed = job?['status'] == 'failed' || job?['error'] != null;
    final stage = switch (job?['status']) {
      'transcribing' =>
        'Transcription ${job?['transcribedChunks'] ?? 0}/${job?['chunkCount'] ?? '?'}',
      'reading_notes' => 'Lecture des manuscrits…',
      'organizing' => 'Classement…',
      'drafting' => 'Rédaction…',
      'applying' => 'Enregistrement…',
      'complete' => null,
      'failed' => 'Traitement interrompu',
      _ => job == null ? null : 'Envoi en cours…',
    };
    final warnings = ((job?['result'] as Map?)?['warnings'] as List? ?? [])
        .whereType<String>()
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            if (_jobs.length > 1)
              DropdownButton<String>(
                value: _selected,
                underline: const SizedBox.shrink(),
                items: _jobs
                    .map(
                      (j) => DropdownMenuItem(
                        value: j['id'] as String,
                        child: Text(_visitLabel(j)),
                      ),
                    )
                    .toList(),
                onChanged: (id) => setState(() => _selected = id),
              )
            else
              Text(
                job == null ? 'Transcription et questions' : _visitLabel(job),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                if (stage != null)
                  Text(
                    stage,
                    style: TextStyle(
                      color: failed
                          ? Colors.orange.shade900
                          : Colors.grey.shade700,
                    ),
                  ),
                if (failed)
                  TextButton(
                    onPressed: () async {
                      try {
                        await _service.retry(
                          widget.dossierId,
                          job!['id'] as String,
                        );
                        await _load();
                      } catch (_) {
                        if (mounted) {
                          setState(
                            () => _error = 'La reprise n’a pas pu démarrer.',
                          );
                        }
                      }
                    },
                    child: const Text('Reprendre'),
                  ),
                if (warnings.isNotEmpty)
                  TextButton.icon(
                    icon: const Icon(Icons.info_outline, size: 18),
                    label: Text('${warnings.length} points à vérifier'),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Points à vérifier'),
                        content: SizedBox(
                          width: 480,
                          child: SingleChildScrollView(
                            child: Text(
                              warnings.map((w) => '• $w').join('\n\n'),
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Fermer'),
                          ),
                        ],
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Actualiser',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : VisitTranscriptWorkspace(
                  key: ValueKey('${widget.dossierId}:$_selected'),
                  transcript: (job?['transcript'] as List? ?? [])
                      .whereType<Map>()
                      .map((s) => Map<String, dynamic>.from(s))
                      .toList(),
                  onAsk: (question) => _service.ask(
                    widget.dossierId,
                    job!['id'] as String,
                    question,
                  ),
                ),
        ),
      ],
    );
  }
}
