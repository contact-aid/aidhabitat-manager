import 'package:flutter/material.dart';

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
    return IconButton(
      tooltip: toDocuments
          ? 'Ouvrir les documents du dossier'
          : 'Revenir au relevé de visite',
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: const Color(0xFFF2ECF5),
        foregroundColor: const Color(0xFF554265),
        shape: const CircleBorder(side: BorderSide(color: Color(0xFFD8D0DC))),
        padding: EdgeInsets.zero,
        minimumSize: const Size.square(40),
        fixedSize: const Size.square(40),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(
        toDocuments ? Icons.folder_open_outlined : Icons.assignment_outlined,
        size: 18,
      ),
    );
  }
}
