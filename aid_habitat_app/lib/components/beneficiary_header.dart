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
/// Affiche dans l'ordre :
///   1. Bouton retour (chevron gauche 32×32, coins arrondis de 8)
///   2. NOM Prénom (Nunito 22px w600 ink-900, max 380pt + ellipsis)
///   3. Badge type d'accompagnement (AccompanimentBadge large)
///   4. Badge catégorie de revenu (IncomeCategoryBadge large, si non-vide)
///   5. Icône map-pin + adresse complète (rue · cp ville)
///   6. Badge statut ANAH à droite (AnahStatusBadge large, si non-vide)
///   7. Slot optionnel `trailing` (utilisé par VAD pour le bouton « Générer »)
///
/// Demande utilisateur 2026-05-15 : « la ligne qui apparait en haut du
/// relevé de visite doit apparaitre aussi en haut du dossier et de
/// l'espace documents — même couleur, même taille, même position ».
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
    final addressLine = [
      patient.address.trim(),
      [
        patient.zipCode.trim(),
        patient.city.trim(),
      ].where((s) => s.isNotEmpty).join(' '),
    ].where((s) => s.isNotEmpty).join(' · ');

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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBackButton(),
        const SizedBox(width: 16),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth.clamp(0.0, 380.0),
                  ),
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
                AccompanimentBadge(
                  value: accompanimentLabel.isNotEmpty
                      ? accompanimentLabel
                      : 'complet',
                  rawType: dossier.natureAccompagnement.trim().isNotEmpty
                      ? dossier.natureAccompagnement
                      : 'complet',
                  large: true,
                ),
                if (incomeLabel.isNotEmpty)
                  IncomeCategoryBadge(value: incomeLabel, large: true),
                if (addressLine.isNotEmpty)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth.clamp(0.0, 360.0),
                    ),
                    child: Tooltip(
                      message: addressLine,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            LucideIcons.mapPin,
                            size: 18,
                            color: Color(0xFF8A939D),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              addressLine,
                              style: GoogleFonts.nunito(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF5C6670),
                              ),
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    // Keep the status with the navigation actions, outside the identity area.
    // Long names and addresses wrap within their available width instead of
    // pushing the status behind Documents or creating a horizontal scroller.
    final actions = Wrap(
      spacing: 12,
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
        if (trailing == null && anahStatus.isEmpty) return identity;
        if (constraints.maxWidth < 700) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identity,
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
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
