import 'package:flutter/material.dart';

/// One continuous outline shared by a note's header and white editing area.
class NotePanelFrame extends StatelessWidget {
  const NotePanelFrame({super.key, required this.header, required this.child});

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFE4E7EB)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(child: child),
      ],
    ),
  );
}
