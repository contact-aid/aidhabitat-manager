import 'package:flutter/material.dart';

String transcriptTime(num seconds) {
  final total = seconds.toInt();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// Pure workspace: loading, ownership and network calls stay in the parent tab.
class VisitTranscriptWorkspace extends StatefulWidget {
  const VisitTranscriptWorkspace({
    super.key,
    required this.transcript,
    required this.onAsk,
  });
  final List<Map<String, dynamic>> transcript;
  final Future<Map<String, dynamic>> Function(String question) onAsk;
  @override
  State<VisitTranscriptWorkspace> createState() =>
      _VisitTranscriptWorkspaceState();
}

class _VisitTranscriptWorkspaceState extends State<VisitTranscriptWorkspace> {
  final _question = TextEditingController();
  final _transcriptScroll = ScrollController(),
      _chatScroll = ScrollController();
  final _anchors = <int, GlobalKey>{};
  final _messages = <Map<String, dynamic>>[];
  final _highlights = <int, List<String>>{};
  bool _asking = false;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    _transcriptScroll.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final question = _question.text.trim();
    if (question.isEmpty || _asking || widget.transcript.isEmpty) return;
    setState(() {
      _asking = true;
      _error = null;
    });
    try {
      final answer = await widget.onAsk(question);
      if (!mounted) return;
      setState(() {
        _messages.add({'question': question, ...answer});
        _question.clear();
      });
      await _reveal(answer);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _chatScroll.hasClients) {
          _chatScroll.animateTo(
            _chatScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Réponse indisponible. Réessaie.');
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<void> _reveal(Map<String, dynamic> message, [int? selected]) async {
    final indices = (message['sources'] as List? ?? [])
        .whereType<int>()
        .where((i) => widget.transcript.any((s) => s['index'] == i))
        .toList();
    setState(() {
      _highlights.clear();
      for (final index in indices) {
        final quotes = (message['citations'] as List? ?? [])
            .whereType<Map>()
            .where((c) => c['index'] == index && c['quote'] is String)
            .map((c) => c['quote'] as String)
            .where((q) => q.isNotEmpty)
            .toList();
        _highlights[index] = quotes;
      }
    });
    final target = selected ?? indices.firstOrNull;
    if (target == null) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final anchor = _anchors[target]?.currentContext;
    if (anchor != null && anchor.mounted) {
      await Scrollable.ensureVisible(
        anchor,
        alignment: 0.15,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _panel(String title, Widget body, {Widget? trailing}) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE6E1EC)),
      borderRadius: BorderRadius.circular(16),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: const Color(0xFFF3EFF7),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        Expanded(child: body),
      ],
    ),
  );

  Widget _avatar(Map turn) {
    final role = turn['role'];
    final voice = turn['voice'];
    final icon = role == 'therapist'
        ? '👩‍⚕️'
        : voice == 'woman'
        ? '👩'
        : voice == 'man'
        ? '👨'
        : null;
    final label = role == 'therapist'
        ? 'Ergothérapeute · rôle proposé'
        : voice == 'woman'
        ? 'Voix féminine présumée'
        : voice == 'man'
        ? 'Voix masculine présumée'
        : 'Interlocuteur';
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0xFFF3EFF7),
            shape: BoxShape.circle,
          ),
          child: icon == null
              ? const Icon(
                  Icons.person_outline,
                  size: 20,
                  color: Color(0xFF89719B),
                )
              : Text(
                  icon,
                  style: const TextStyle(
                    fontSize: 20,
                    fontFamilyFallback: [
                      'Apple Color Emoji',
                      'Noto Color Emoji',
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _turns(Map<String, dynamic> segment) {
    final turns = (segment['turns'] as List? ?? []).whereType<Map>().toList();
    if (turns.isNotEmpty) {
      return turns.map((t) => Map<String, dynamic>.from(t)).toList();
    }
    final text = segment['text'] as String? ?? '';
    // Old recordings have no structured speakers. Remove only explicit labels,
    // preserving all spoken words. Never infer a role from an ordinary question.
    final label = RegExp(
      r'(?:^|\n)\s*(?:\*\*)?(Voix non identifi[ée]e?|Voix\s*\d+|Ergoth[ée]rapeute|Ergo|Intervenante?|Madame|Monsieur)(?:\*\*)?\s*:',
      caseSensitive: false,
    );
    final matches = label.allMatches(text).toList();
    if (matches.isEmpty) {
      return [
        {'text': text},
      ];
    }
    final result = <Map<String, dynamic>>[];
    if (matches.first.start > 0 &&
        text.substring(0, matches.first.start).trim().isNotEmpty) {
      result.add({'text': text.substring(0, matches.first.start).trim()});
    }
    for (var i = 0; i < matches.length; i++) {
      final name = matches[i].group(1)!.toLowerCase();
      result.add({
        'text': text
            .substring(
              matches[i].end,
              i + 1 < matches.length ? matches[i + 1].start : text.length,
            )
            .trim(),
        'role': name.startsWith('ergo') ? 'therapist' : 'unknown',
        'voice': name == 'madame'
            ? 'woman'
            : name == 'monsieur'
            ? 'man'
            : 'unknown',
      });
    }
    return result;
  }

  TextSpan _highlighted(String text, List<String> quotes) {
    final ranges = <(int, int)>[];
    for (final quote in quotes) {
      var at = text.indexOf(quote);
      while (at >= 0) {
        ranges.add((at, at + quote.length));
        at = text.indexOf(quote, at + quote.length);
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range.$2 <= cursor) continue;
      final start = range.$1 < cursor ? cursor : range.$1;
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(start, range.$2),
          style: const TextStyle(backgroundColor: Color(0xFFE9E9EB)),
        ),
      );
      cursor = range.$2;
    }
    spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(children: spans);
  }

  Widget _transcript() => _panel(
    'Transcription',
    widget.transcript.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'La transcription apparaîtra ici.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : Scrollbar(
            controller: _transcriptScroll,
            child: SingleChildScrollView(
              key: const ValueKey('transcript-scroll'),
              controller: _transcriptScroll,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.transcript.map((segment) {
                  final index = segment['index'] as int;
                  final selected = _highlights.containsKey(index);
                  final quotes = _highlights[index] ?? [];
                  final turns = _turns(segment);
                  final preciseMatch = quotes.any(
                    (quote) => turns.any(
                      (turn) => (turn['text'] as String? ?? '').contains(quote),
                    ),
                  );
                  return Container(
                    key: _anchors.putIfAbsent(index, GlobalKey.new),
                    margin: const EdgeInsets.only(bottom: 18),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: selected && !preciseMatch
                          ? const Color(0xFFF1F1F3)
                          : null,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          transcriptTime(segment['startSeconds'] as num? ?? 0),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF8B8192),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...turns.map(
                          (turn) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _avatar(turn),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: SelectableText.rich(
                                    _highlighted(
                                      turn['text'] as String? ?? '',
                                      quotes,
                                    ),
                                    style: const TextStyle(
                                      fontSize: 14,
                                      height: 1.65,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
  );

  Widget _chat() => _panel(
    'Questions sur la visite',
    Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 30,
                          color: Color(0xFFAC98BC),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Que souhaites-tu retrouver ?',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Les passages cités s’éclairent dans la transcription.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF81768A),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  controller: _chatScroll,
                  padding: const EdgeInsets.all(18),
                  children: _messages
                      .map(
                        (message) => Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3EFF7),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    message['question'] as String,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              SelectableText(
                                message['answer'] as String? ?? '',
                                style: const TextStyle(height: 1.6),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: (message['sources'] as List? ?? [])
                                    .whereType<int>()
                                    .map((index) {
                                      final source = widget.transcript
                                          .where((s) => s['index'] == index)
                                          .firstOrNull;
                                      if (source == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return ActionChip(
                                        avatar: const Icon(
                                          Icons.format_quote,
                                          size: 16,
                                        ),
                                        label: Text(
                                          transcriptTime(
                                            source['startSeconds'] as num? ?? 0,
                                          ),
                                        ),
                                        tooltip: 'Voir le passage cité',
                                        onPressed: () =>
                                            _reveal(message, index),
                                      );
                                    })
                                    .toList(),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('visit-question'),
                  controller: _question,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  enabled: widget.transcript.isNotEmpty && !_asking,
                  decoration: InputDecoration(
                    hintText: 'Pose une question…',
                    counterText: '',
                    filled: true,
                    fillColor: const Color(0xFFFAF9FC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE6E1EC)),
                    ),
                    contentPadding: const EdgeInsets.all(12),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: 'Envoyer la question',
                onPressed: widget.transcript.isEmpty || _asking ? null : _ask,
                icon: _asking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 700) {
        return Column(
          children: [
            Expanded(flex: 5, child: _transcript()),
            const SizedBox(height: 12),
            Expanded(flex: 4, child: _chat()),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 6, child: _transcript()),
          const SizedBox(width: 16),
          Expanded(flex: 4, child: _chat()),
        ],
      );
    },
  );
}
