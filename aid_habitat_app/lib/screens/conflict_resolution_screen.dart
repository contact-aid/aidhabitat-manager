import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/data_service.dart';
import '../services/dossier_repository.dart';
import '../services/sync_mutation.dart';

class ConflictResolutionScreen extends StatefulWidget {
  const ConflictResolutionScreen({
    super.key,
    required this.localDossier,
    required this.onResolved,
    this.loadReviews,
    this.resolveReview,
  });

  final Dossier localDossier;
  final VoidCallback onResolved;
  final Future<List<SyncConflictReview>> Function()? loadReviews;
  final Future<void> Function(SyncConflictReview, bool)? resolveReview;

  @override
  State<ConflictResolutionScreen> createState() =>
      _ConflictResolutionScreenState();
}

class _ConflictResolutionScreenState extends State<ConflictResolutionScreen> {
  List<SyncConflictReview> _reviews = [];
  bool _loading = true;
  bool _resolving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_resolving) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final reviews =
          await (widget.loadReviews?.call() ??
              DataService().reviewDossierConflicts(widget.localDossier.id));
      if (!mounted) return;
      setState(() {
        _reviews = reviews;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is StateError
            ? 'Comparaison indisponible : ${error.message} Vos modifications restent sur cet appareil.'
            : 'Comparaison indisponible. Vos modifications restent sur cet appareil.';
      });
    }
  }

  Future<void> _resolve(SyncConflictReview review, bool keepLocal) async {
    if (_resolving || _loading || _error != null) return;
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      if (widget.resolveReview != null) {
        await widget.resolveReview!(review, keepLocal);
      } else {
        await DataService().resolveReviewedConflict(
          review,
          keepLocal: keepLocal,
        );
      }
      if (!mounted) return;
      setState(() {
        _reviews.remove(review);
        _resolving = false;
      });
      if (_reviews.isEmpty) widget.onResolved();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error =
            'Choix non applique. Rechargez la comparaison avant de reessayer.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_resolving,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Conflits de synchronisation'),
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: 'Retour',
          onPressed: _resolving ? null : () => Navigator.pop(context),
          icon: const Icon(LucideIcons.chevronLeft),
        ),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _loading || _resolving ? null : _load,
            icon: const Icon(LucideIcons.refreshCw),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  '${widget.localDossier.patient.firstName} ${widget.localDossier.patient.lastName}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_reviews.isEmpty && _error == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('Aucun conflit resoluble sur cette fiche.'),
                  ),
                for (final review in _reviews) _buildReview(review),
              ],
            ),
    ),
  );

  Widget _buildReview(SyncConflictReview review) {
    final title = switch (review.entityType) {
      'patient' => 'Beneficiaire',
      'housing' => 'Logement',
      'mesures_anthropometriques' => 'Mesures',
      'observations_synthese' => 'Observations de synthese',
      'diagnostic_sanitaires' => 'Diagnostic sanitaires',
      _ => 'Dossier',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            describeSyncConflict(
              jsonDecode(review.payloadJson) as Map<String, dynamic>,
            ),
          ),
          const SizedBox(height: 12),
          for (final key in review.localValues.keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _fieldLabels[key] ?? key,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final local = _value(
                        'Cet appareil',
                        review.localValues[key],
                      );
                      final remote = _value(
                        'Serveur',
                        review.remoteValues[key],
                      );
                      return constraints.maxWidth < 600
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                local,
                                const SizedBox(height: 8),
                                remote,
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: local),
                                const SizedBox(width: 20),
                                Expanded(child: remote),
                              ],
                            );
                    },
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _resolving || _error != null
                    ? null
                    : () => _resolve(review, true),
                icon: const Icon(LucideIcons.uploadCloud),
                label: const Text('Conserver mes changements'),
              ),
              OutlinedButton.icon(
                onPressed: _resolving || _error != null
                    ? null
                    : () => _resolve(review, false),
                icon: const Icon(LucideIcons.downloadCloud),
                label: const Text('Prendre ces valeurs du serveur'),
              ),
            ],
          ),
          if (_resolving) const LinearProgressIndicator(),
          const SizedBox(height: 20),
          const Divider(),
        ],
      ),
    );
  }

  Widget _value(String title, dynamic value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      SelectableText(
        value == null || value == ''
            ? 'Non renseigne'
            : value is Map || value is List
            ? const JsonEncoder.withIndent('  ').convert(value)
            : value.toString(),
      ),
    ],
  );
}

const _fieldLabels = {
  'firstName': 'Prenom',
  'lastName': 'Nom',
  'phone': 'Telephone',
  'email': 'E-mail',
  'address': 'Adresse',
  'city': 'Commune',
  'zipCode': 'Code postal',
  'familySituation': 'Situation familiale',
  'occupationStatus': 'Statut d\'occupation',
  'occupant1BirthDate': 'Date de naissance',
  'trustedPerson': 'Personne de confiance',
  'occupants': 'Occupants',
  'invalidity': 'Invalidité',
  'invalidityTxt': 'Précisions sur l’invalidité',
  'incomeCategory': 'Categorie de revenus',
  'fiscalRevenue': 'Revenu fiscal',
  'numberPeople': 'Nombre de personnes',
  'surface': 'Surface',
  'typology': 'Type de logement',
  'roomsBreakdown': 'Pieces par niveau',
  'heatingDetails': 'Chauffage',
  'status': 'Statut',
  'visitDate': 'Date de visite',
  'ergoId': 'Ergotherapeute',
  'beneficiaryPrepared': 'Beneficiaire prepare',
  'compteAnah': 'Compte ANAH',
  'natureAccompagnement': 'Accompagnement',
  'envoiRapport': 'Envoi du rapport',
  'personnesPresentesVisite': 'Personnes presentes',
  'deboutHauteurCoude': 'Hauteur du coude debout',
  'assisHauteurAssise': "Hauteur d'assise",
  'assisProfondeurGenoux': 'Profondeur aux genoux',
  'assisHauteurCoudes': 'Hauteur des coudes assis',
  'observations': 'Observations',
  'observationEquipements': 'Observations sur les equipements',
  'projetSouhaitUsage': "Projet et souhaits de l'usager",
  'resumePreconisations': 'Resume des preconisations',
  'sdbInstances': 'Salles de bain',
  'wcInstances': 'WC',
};
