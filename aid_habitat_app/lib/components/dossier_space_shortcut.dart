import 'package:flutter/material.dart';
import 'cta_text_style.dart';

class DossierSpaceShortcut extends StatelessWidget {
  final bool toDocuments;
  final VoidCallback? onPressed;

  const DossierSpaceShortcut({
    super.key,
    required this.toDocuments,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final label = toDocuments ? 'Documents' : 'Relevé de visite';
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Tooltip(
      message: toDocuments
          ? 'Ouvrir les documents du dossier'
          : 'Revenir au relevé de visite',
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFFF2ECF5),
          foregroundColor: const Color(0xFF554265),
          shape: const StadiumBorder(
            side: BorderSide(color: Color(0xFFD8D0DC)),
          ),
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
          minimumSize: const Size(40, 36),
          fixedSize: const Size.fromHeight(36),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: kCtaTextStyle,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              toDocuments
                  ? Icons.folder_open_outlined
                  : Icons.assignment_outlined,
              size: 18,
              semanticLabel: compact ? label : null,
            ),
            if (!compact) ...[const SizedBox(width: 8), Text(label)],
          ],
        ),
      ),
    );
  }
}
