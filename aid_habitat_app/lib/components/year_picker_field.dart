import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'soft_transitions.dart';

class YearPickerField extends StatelessWidget {
  const YearPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.showWarning = false,
    this.warningText,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool showWarning;
  final String? warningText;

  Future<void> _pickYear(BuildContext context) async {
    final now = DateTime.now().year;
    final parsed = int.tryParse(value.trim());
    final years = List<int>.generate(now - 1700 + 2, (i) => now + 1 - i);
    final initialValue = parsed != null && years.contains(parsed)
        ? parsed
        : now;
    final initialIdx = years.indexOf(initialValue);
    final scrollCtrl = ScrollController(
      initialScrollOffset: initialIdx > 5 ? ((initialIdx ~/ 3) - 1) * 56.0 : 0,
    );

    final picked = await showSoftDialog<int>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        int pending = initialValue;
        bool closing = false;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            title: Text(
              label,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.25,
                color: Color(0xFF0E1116),
              ),
            ),
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            content: SizedBox(
              width: 320,
              height: 360,
              child: Scrollbar(
                controller: scrollCtrl,
                child: GridView.builder(
                  controller: scrollCtrl,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 2.2,
                  ),
                  itemCount: years.length,
                  itemBuilder: (_, i) {
                    final isSelected = years[i] == pending;
                    return InkWell(
                      onTap: closing
                          ? null
                          : () {
                              final selectedValue = years[i];
                              setLocal(() {
                                pending = selectedValue;
                                closing = true;
                              });
                              Future.delayed(
                                const Duration(milliseconds: 180),
                                () {
                                  if (!dialogCtx.mounted) return;
                                  if (Navigator.of(dialogCtx).canPop()) {
                                    Navigator.pop(dialogCtx, selectedValue);
                                  }
                                },
                              );
                            },
                      borderRadius: BorderRadius.circular(10),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFF0E1116)
                              : const Color(0xFFF2F4F6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          style: DefaultTextStyle.of(ctx).style.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFF0E1116),
                            decoration: TextDecoration.none,
                          ),
                          child: Text('${years[i]}'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.only(right: 16, bottom: 8),
            actions: [
              TextButton(
                onPressed: closing
                    ? null
                    : () => Navigator.pop(dialogCtx, null),
                child: const Text(
                  'Annuler',
                  style: TextStyle(
                    color: Color(0xFF5C6670),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    onChanged('$picked');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: Color(0xFF0E1116),
          ),
        ),
        const SizedBox(height: 5),
        InkWell(
          onTap: () => _pickYear(context),
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(
                color: showWarning
                    ? const Color(0xFFC48429)
                    : const Color(0xFFB9C0C7),
                width: showWarning ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value.trim().isEmpty ? 'Sélectionner' : value.trim(),
                    style: TextStyle(
                      fontSize: 14,
                      color: value.trim().isEmpty
                          ? const Color(0xFF8A939D)
                          : const Color(0xFF2B323A),
                    ),
                  ),
                ),
                if (value.trim().isNotEmpty)
                  IconButton(
                    tooltip: 'Effacer',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    onPressed: () => onChanged(''),
                    icon: const Icon(
                      LucideIcons.x,
                      size: 16,
                      color: Color(0xFF8A939D),
                    ),
                  )
                else
                  Icon(
                    LucideIcons.calendarDays,
                    size: 16,
                    color: showWarning
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF8A939D),
                  ),
              ],
            ),
          ),
        ),
        if (showWarning && warningText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              warningText!,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFFF59E0B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}
