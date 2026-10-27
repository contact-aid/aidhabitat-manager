import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../models/dossier_occupants.dart';
import 'beneficiary_badges.dart';

/// Header bénéficiaire partagé entre :
///   - `DossierScreen` (page dossier, avant d'aller en VAD ou Documents)
///   - `DocumentsScreen` (espace documents du bénéficiaire)
///   - `VisitReportScreen` (relevé de visite VAD)
///
/// Identité et badges à gauche ; statut Anah puis commandes à droite.
/// Sur les petites largeurs, les commandes passent sous l’identité sans
/// défilement horizontal pour garder l’enregistrement et son arrêt visibles.
class BeneficiaryHeader extends StatelessWidget {
  final Dossier dossier;
  final VoidCallback onBack;
  final List<Occupant>? occupants;

  /// Widget optionnel à afficher tout à droite (après le badge Anah).
  /// Utilisé par le relevé de visite pour le bouton « Générer ».
  final Widget? trailing;

  const BeneficiaryHeader({
    super.key,
    required this.dossier,
    required this.onBack,
    this.occupants,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final patient = dossier.patient;
    final accompanimentLabel = formatAccompanimentType(
      dossier.natureAccompagnement,
    ).trim();
    final incomeLabel = patient.incomeCategory.trim();
    // Statut Anah parsé depuis le JSON compteAnah (cf.
    // beneficiary_tab._parseAnahData). Tolère le format legacy
    // « plain string » et la valeur historique « Mandat » (= pas de
    // statut associé).
    String anahStatus = '';
    final anahRaw = dossier.compteAnah.trim();
    if (anahRaw.isNotEmpty) {
      if (anahRaw.startsWith('{')) {
        try {
          final decoded = jsonDecode(anahRaw);
          if (decoded is Map) {
            anahStatus = (decoded['status']?.toString() ?? '').trim();
          }
        } catch (_) {
          /* laisse vide */
        }
      } else if (anahRaw != 'Mandat') {
        anahStatus = anahRaw;
      }
    }

    final identity = Row(
      children: [
        _buildBackButton(),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Text(
                    dossierBeneficiaryTitle(patient, occupants: occupants),
                    style: GoogleFonts.nunito(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.4,
                      color: const Color(0xFF0E1116),
                    ),
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AccompanimentBadge(
                value: accompanimentLabel.isNotEmpty
                    ? accompanimentLabel
                    : 'complet',
                rawType: dossier.natureAccompagnement.trim().isNotEmpty
                    ? dossier.natureAccompagnement
                    : 'complet',
                large: true,
              ),
              if (incomeLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                IncomeCategoryBadge(value: incomeLabel, large: true),
              ],
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 10,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (anahStatus.isNotEmpty)
          AnahStatusBadge(status: anahStatus, large: true),
        if (trailing != null) trailing!,
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (anahStatus.isEmpty && trailing == null) return identity;
        if (constraints.maxWidth < 1000) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [identity, const SizedBox(height: 4), actions],
          );
        }
        return Row(
          children: [
            Expanded(child: identity),
            const SizedBox(width: 12),
            actions,
          ],
        );
      },
    );
  }

  /// Bouton retour 32×32, aligné sur la hauteur des badges, avec fond permanent.
  /// Le fond reprend la
  /// couleur qui n'apparaissait auparavant qu'au survol.
  Widget _buildBackButton() {
    return Material(
      color: const Color(0xFFF2ECF5),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onBack,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFFF2ECF5),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: const Icon(
            LucideIcons.chevronLeft,
            size: 18,
            color: Color(0xFF2B323A), // ink-700
          ),
        ),
      ),
    );
  }
}
