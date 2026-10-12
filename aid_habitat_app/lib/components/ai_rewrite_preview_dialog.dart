import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

const _kActiveText = Color(0xFF554265);

class AiRewritePreviewDialog extends StatefulWidget {
  const AiRewritePreviewDialog({
    super.key,
    required this.originalText,
    required this.generate,
    required this.onCancel,
    required this.phase,
  });

  final String originalText;
  final Future<String> Function(BuildContext) generate;
  final VoidCallback onCancel;
  final String Function() phase;

  @override
  State<AiRewritePreviewDialog> createState() => _AiRewritePreviewDialogState();
}

class _AiRewritePreviewDialogState extends State<AiRewritePreviewDialog> {
  late final TextEditingController _proposalController;
  bool _generating = true;
  String? _error;
  String _phase = 'Préparation de la reformulation…';
  Timer? _timer;
  final Stopwatch _elapsed = Stopwatch();

  @override
  void initState() {
    super.initState();
    _proposalController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _generate());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_generating) widget.onCancel();
    _proposalController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (!mounted) return;
    setState(() {
      _generating = true;
      _error = null;
    });
    _elapsed
      ..reset()
      ..start();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final phase = widget.phase();
      setState(
        () => _phase = phase.isEmpty ? 'Reformulation en cours…' : phase,
      );
    });
    try {
      final result = await widget.generate(context);
      if (mounted) setState(() => _proposalController.text = result);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst(
            RegExp(r'^Exception:\s*'),
            '',
          ),
        );
      }
    } finally {
      _timer?.cancel();
      _elapsed.stop();
      if (mounted) setState(() => _generating = false);
    }
  }

  Widget _buildWaiting() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: _kActiveText,
          ),
        ),
        const SizedBox(height: 20),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            _phase,
            key: ValueKey(_phase),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _kActiveText,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (_elapsed.elapsed.inSeconds >= 5) ...[
          const SizedBox(height: 12),
          const Text(
            'Le moteur local prend un peu plus de temps.\nVous pouvez conserver l’original à tout moment.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFF5C6670)),
          ),
        ],
      ],
    ),
  );

  Widget _buildTextPanel({
    required String label,
    required String text,
    required bool highlighted,
    TextEditingController? controller,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              highlighted ? LucideIcons.sparkles : LucideIcons.fileText,
              size: 16,
              color: highlighted ? _kActiveText : const Color(0xFF5C6670),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: highlighted
                  ? const Color(0xFFFAF7FC)
                  : const Color(0xFFF8F9FA),
              border: Border.all(
                color: highlighted
                    ? const Color(0xFFD9CCE2)
                    : const Color(0xFFE4E7EB),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: highlighted && _generating
                ? _buildWaiting()
                : highlighted && _error != null
                ? Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFF5C6670)),
                          ),
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: _generate,
                            icon: const Icon(LucideIcons.refreshCw, size: 16),
                            label: const Text('Réessayer'),
                          ),
                        ],
                      ),
                    ),
                  )
                : controller == null
                ? SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: const TextStyle(
                        height: 1.45,
                        fontSize: 14,
                        color: Color(0xFF111827),
                      ),
                    ),
                  )
                : TextField(
                    controller: controller,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration.collapsed(
                      hintText: 'Modifier la proposition…',
                    ),
                    style: const TextStyle(
                      height: 1.45,
                      fontSize: 14,
                      color: Color(0xFF111827),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    final dialogWidth = math.min(860.0, screen.width - 32);
    final availableHeight = screen.height - keyboardHeight - 48;
    final dialogHeight = math.min(620.0, math.max(280.0, availableHeight));

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    LucideIcons.sparkles,
                    size: 20,
                    color: _kActiveText,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Vérifier la reformulation',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(LucideIcons.x, size: 19),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Relisez et ajustez la proposition avant de remplacer votre note.',
                style: TextStyle(fontSize: 14, color: Color(0xFF5C6670)),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final original = _buildTextPanel(
                      label: 'Note originale',
                      text: widget.originalText,
                      highlighted: false,
                    );
                    final rewritten = _buildTextPanel(
                      label: 'Proposition modifiable',
                      text: _proposalController.text,
                      highlighted: true,
                      controller: _proposalController,
                    );
                    if (constraints.maxWidth < 620) {
                      return Column(
                        children: [
                          Expanded(child: original),
                          const SizedBox(height: 16),
                          Expanded(child: rewritten),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: original),
                        const SizedBox(width: 18),
                        Expanded(child: rewritten),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Conserver l’original'),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _proposalController,
                    builder: (context, value, _) => FilledButton.icon(
                      onPressed:
                          _generating ||
                              _error != null ||
                              value.text.trim().isEmpty
                          ? null
                          : () => Navigator.of(context).pop(value.text.trim()),
                      icon: const Icon(LucideIcons.check, size: 17),
                      label: const Text('Utiliser la proposition'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kActiveText,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
