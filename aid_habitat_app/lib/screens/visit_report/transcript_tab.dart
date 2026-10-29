import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/visit_assistant_service.dart';

class VisitTranscriptTab extends StatefulWidget {
  const VisitTranscriptTab({super.key, required this.dossierId});
  final String dossierId;
  @override
  State<VisitTranscriptTab> createState() => _VisitTranscriptTabState();
}

class _VisitTranscriptTabState extends State<VisitTranscriptTab> {
  final _question = TextEditingController();
  List<Map<String, dynamic>> _jobs = [];
  String? _selected;
  String? _error;
  bool _loading = true;
  bool _asking = false;
  bool _refreshing = false;
  Timer? _refreshTimer;
  final List<Map<String, dynamic>> _messages = [];
  final _service = VisitAssistantService.instance;
  String? _lastProgress;
  @override
  void initState() {
    super.initState();
    _service.addListener(_progress);
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_jobs.any((j) => !['complete', 'failed'].contains(j['status']))) {
        unawaited(_load());
      }
    });
  }

  void _progress() {
    final progress = _service.jobs
        .where((j) => j['dossierId'] == widget.dossierId)
        .map(
          (j) =>
              '${j['id']}:${j['status']}:${(j['remote'] as Map?)?['status']}:${((j['remote'] as Map?)?['transcript'] as List?)?.length}',
        )
        .join();
    if (_lastProgress == progress) return;
    _lastProgress = progress;
    _load();
  }

  Future<void> _load() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final jobs = await _service.loadTranscripts(widget.dossierId);
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        if (!_jobs.any((j) => j['id'] == _selected)) {
          _selected = jobs.isEmpty ? null : jobs.first['id'] as String;
        }
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              'La transcription sera disponible après synchronisation et traitement.';
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _service.removeListener(_progress);
    _refreshTimer?.cancel();
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask(Map<String, dynamic> job) async {
    final question = _question.text.trim();
    if (question.isEmpty || _asking) return;
    setState(() {
      _asking = true;
      _error = null;
    });
    try {
      final answer = await _service.ask(
        widget.dossierId,
        job['id'] as String,
        question,
      );
      if (!mounted) return;
      setState(() {
        _messages.add({'question': question, ...answer});
        _question.clear();
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Réponse indisponible. Vérifie la connexion et réessaie.',
        );
      }
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _jobs.where((j) => j['id'] == _selected).firstOrNull;
    final transcript = (job?['transcript'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final warnings = (job?['result'] as Map?)?['warnings'] as List? ?? [];
    final stage = switch (job?['status']) {
      'transcribing' =>
        'Transcription : ${job?['transcribedChunks'] ?? transcript.length}/${job?['chunkCount'] ?? '?'} extraits',
      'reading_notes' => 'Lecture des notes manuscrites',
      'organizing' => 'Classement des informations',
      'drafting' => 'Rédaction des textes',
      'applying' => 'Enregistrement des textes dans les rubriques',
      'complete' => 'Traitement terminé',
      'failed' =>
        'Traitement arrêté après échecs. Les sources sont conservées.',
      _ => 'Envoi de l’enregistrement',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Transcription et assistant de visite',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Actualiser la transcription',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        ListenableBuilder(
          listenable: _service,
          builder: (_, _) => Text(
            _service.error ??
                (_service.isRecording
                    ? 'Enregistrement en cours. L’audio est sauvegardé sur l’iPad.'
                    : 'Les textes sont ajoutés à la suite de tes notes. Relis-les dans chaque rubrique.'),
            style: TextStyle(
              color: _service.error == null
                  ? Colors.grey.shade700
                  : Colors.orange.shade900,
            ),
          ),
        ),
        if (job != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(child: Text(stage)),
                if (job['status'] == 'failed' || job['error'] != null)
                  TextButton(
                    onPressed: () async {
                      try {
                        await _service.retry(
                          widget.dossierId,
                          job['id'] as String,
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
                    child: const Text('Reprendre le traitement'),
                  ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_error!),
          ),
        if (_jobs.length > 1)
          DropdownButton<String>(
            value: _selected,
            isExpanded: true,
            items: _jobs
                .map(
                  (j) => DropdownMenuItem(
                    value: j['id'] as String,
                    child: Text(
                      'Visite ${j['createdAt'] ?? ''} · ${((j['audioDurationSeconds'] as num? ?? 0) / 60).ceil()} min',
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() {
              _selected = value;
              _messages.clear();
            }),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : transcript.isEmpty
              ? const Center(
                  child: Text(
                    'La transcription apparaîtra ici après le traitement de l’enregistrement.',
                  ),
                )
              : ListView(
                  children: [
                    if (warnings.isNotEmpty)
                      Card(
                        color: Colors.amber.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'Points à vérifier\n${warnings.join('\n')}',
                          ),
                        ),
                      ),
                    ...transcript.map((segment) {
                      final seconds = (segment['startSeconds'] as num? ?? 0)
                          .toInt();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: SelectableText(
                          '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}\n${segment['text']}',
                        ),
                      );
                    }),
                    const Divider(),
                    ..._messages.map(
                      (message) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message['question'] as String,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SelectableText(message['answer'] as String),
                              ...((message['sources'] as List?) ?? []).map((
                                index,
                              ) {
                                final source = transcript
                                    .where((s) => s['index'] == index)
                                    .firstOrNull;
                                if (source == null) {
                                  return const SizedBox.shrink();
                                }
                                final seconds = (source['startSeconds'] as num)
                                    .toInt();
                                return ExpansionTile(
                                  title: Text(
                                    'Source à ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                                  ),
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: SelectableText(
                                        source['text'] as String,
                                      ),
                                    ),
                                  ],
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _question,
                minLines: 1,
                maxLines: 4,
                maxLength: 2000,
                enabled: transcript.isNotEmpty && !_asking,
                decoration: const InputDecoration(
                  hintText: 'Que s’est-il dit sur l’accès à la douche ?',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Poser la question',
              onPressed: job == null || transcript.isEmpty || _asking
                  ? null
                  : () => _ask(job),
              icon: _asking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ],
    );
  }
}
