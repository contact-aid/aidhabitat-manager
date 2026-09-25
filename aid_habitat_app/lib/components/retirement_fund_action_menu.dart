import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'brand_colors.dart';

enum RetirementFundAction { edit, share, duplicate, delete }

/// Reprend à l'identique le menu d'actions des cartes Bibliothèque.
class RetirementFundActionMenu extends StatelessWidget {
  const RetirementFundActionMenu({
    super.key,
    required this.onEdit,
    required this.onShare,
    required this.onDuplicate,
    required this.onDelete,
  });

  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  void _handleAction(RetirementFundAction action) {
    switch (action) {
      case RetirementFundAction.edit:
        onEdit();
      case RetirementFundAction.share:
        onShare();
      case RetirementFundAction.duplicate:
        onDuplicate();
      case RetirementFundAction.delete:
        onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: PopupMenuButton<RetirementFundAction>(
        tooltip: 'Actions',
        icon: const Icon(
          LucideIcons.moreVertical,
          size: 18,
          color: Color(0xFF8A939D),
        ),
        padding: EdgeInsets.zero,
        splashRadius: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onSelected: _handleAction,
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: RetirementFundAction.edit,
            child: _ActionLabel(icon: LucideIcons.pencil, label: 'Modifier'),
          ),
          PopupMenuItem(
            value: RetirementFundAction.share,
            child: _ActionLabel(icon: LucideIcons.share2, label: 'Partager'),
          ),
          PopupMenuItem(
            value: RetirementFundAction.duplicate,
            child: _ActionLabel(icon: LucideIcons.copy, label: 'Dupliquer'),
          ),
          PopupMenuDivider(),
          PopupMenuItem(
            value: RetirementFundAction.delete,
            child: _ActionLabel(
              icon: LucideIcons.trash2,
              label: 'Supprimer',
              color: Color(0xFFB91C1C),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionLabel extends StatelessWidget {
  const _ActionLabel({
    required this.icon,
    required this.label,
    this.color = kBrandDarkPurple,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}
