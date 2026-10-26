import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';
import '../services/data_service.dart';
import '../services/dossier_repository.dart';
import '../services/sync_mutation.dart';
import '../services/collection_mutation_contract.dart';

class ConflictResolutionScreen extends StatefulWidget {
  const ConflictResolutionScreen({
    super.key,
    required this.localDossier,
    required this.onResolved,
    this.onReviewApplied,
    this.loadReviews,
    this.resolveReview,
    this.resolveFields,
  });

  final Dossier localDossier;
  final VoidCallback onResolved;
  final ValueChanged<String>? onReviewApplied;
  final Future<List<SyncConflictReview>> Function()? loadReviews;
  final Future<void> Function(SyncConflictReview, bool)? resolveReview;
  final Future<void> Function(SyncConflictReview, Set<String>)? resolveFields;

  @override
  State<ConflictResolutionScreen> createState() =>
      _ConflictResolutionScreenState();
}

class _ConflictResolutionScreenState extends State<ConflictResolutionScreen> {
  List<SyncConflictReview> _reviews = [];
  bool _loading = true;
  bool _resolving = false;
  String? _error;
  final Map<String, Map<String, bool>> _fieldChoices = {};

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
        _fieldChoices.clear();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Comparaison momentanément indisponible. Vos modifications restent sur cet appareil. Vérifiez Internet puis actualisez.';
      });
    }
  }

  Future<void> _resolve(
    SyncConflictReview review,
    bool keepLocal, {
    Set<String>? localFields,
  }) async {
    if (_resolving || _loading || _error != null) return;
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      if (localFields != null && widget.resolveFields != null) {
        await widget.resolveFields!(review, localFields);
      } else if (localFields == null && widget.resolveReview != null) {
        await widget.resolveReview!(review, keepLocal);
      } else {
        await DataService().resolveReviewedConflict(
          review,
          keepLocal: keepLocal,
          localFields: localFields,
        );
      }
      if (!mounted) return;
      setState(() {
        _reviews.remove(review);
        _resolving = false;
      });
      widget.onReviewApplied?.call(review.entityType);
      if (_reviews.isEmpty) widget.onResolved();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error =
            'Choix non appliqué. Actualisez la comparaison pour réessayer. Vos saisies sont conservées.';
      });
    }
  }

  Future<void> _retryOriginal(SyncConflictReview review) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      if (!await DataService().retryOriginalOccupantConflict(review)) {
        throw StateError('La saisie a changé.');
      }
      if (!mounted) return;
      setState(() {
        _reviews.remove(review);
        _resolving = false;
      });
      widget.onReviewApplied?.call(review.entityType);
      if (_reviews.isEmpty) widget.onResolved();
    } catch (_) {
      if (mounted) {
        setState(() {
          _resolving = false;
          _error =
              'Nouvelle tentative impossible. Actualisez la comparaison et vérifiez votre compte.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_resolving,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Informations à vérifier'),
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
                    child: Text(
                      'Aucune information à vérifier sur cette fiche.',
                    ),
                  ),
                for (final review in _reviews) _buildReview(review),
              ],
            ),
    ),
  );

  Widget _buildReview(SyncConflictReview review) {
    final title = switch (review.entityType) {
      'patient' => 'Bénéficiaire',
      'housing' => 'Logement',
      'contexte_de_vie' => 'Contexte de vie et autonomie',
      'mesures_anthropometriques' => 'Mesures',
      'observations_synthese' => 'Observations de synthese',
      'diagnostic_sanitaires' => 'Diagnostic sanitaires',
      'visit_recommendations' => 'Préconisations',
      _ => 'Dossier',
    };
    final selective =
        const {'patient', 'housing', 'dossier'}.contains(review.entityType) &&
        review.remoteExists &&
        review.localValues.length > 1;
    final automatic = <String, bool>{};
    final payload = jsonDecode(review.payloadJson) as Map<String, dynamic>;
    final guard = payload['concurrency'];
    final conflict = payload['conflict'];
    if (selective &&
        guard is Map &&
        guard['baseValues'] is Map &&
        !(conflict is Map && conflict['code'] == 'LOCAL_EDIT_BASE_CHANGED')) {
      final plan = planSyncMerge(
        baseValues: Map<String, dynamic>.from(guard['baseValues'] as Map),
        updates: review.localValues,
        remoteValues: review.remoteValues,
      );
      for (final key in review.localValues.keys) {
        final legacyCollection =
            hasCollectionUpdates(review.entityType, {
              key: review.localValues[key],
            }) &&
            guard['collectionContract'] != collectionMutationContract;
        if (!legacyCollection && !plan.conflictingFields.contains(key)) {
          automatic[key] = plan.updates.containsKey(key);
        }
      }
    }
    final choices = _fieldChoices.putIfAbsent(
      review.operationId,
      () => {...automatic},
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Choisissez la version à garder pour chaque information. Vous pouvez revenir plus tard : vos saisies restent enregistrées.',
          ),
          const SizedBox(height: 12),
          if (automatic.isNotEmpty)
            Text(
              '${automatic.length} information(s) sans conflit seront conservées automatiquement.',
            ),
          for (final key in review.localValues.keys.where(
            (key) => !automatic.containsKey(key),
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    conflictFieldLabel(key),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (selective)
                    OutlinedButton(
                      key: ValueKey('choice-${review.operationId}-$key'),
                      onPressed: _resolving || _error != null
                          ? null
                          : () async {
                              final choice = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text(
                                    _fieldLabels[key] ??
                                        'Information du dossier',
                                  ),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _value(
                                          'Sur cet appareil',
                                          review.localValues[key],
                                        ),
                                        const SizedBox(height: 16),
                                        _value(
                                          'Sur le serveur',
                                          review.remoteValues[key],
                                        ),
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Décider plus tard'),
                                    ),
                                    OutlinedButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text(
                                        'Garder la version serveur',
                                      ),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Garder ma version'),
                                    ),
                                  ],
                                ),
                              );
                              if (mounted && choice != null) {
                                setState(() => choices[key] = choice);
                              }
                            },
                      child: Text(
                        choices[key] == null
                            ? 'Choisir la version à garder'
                            : choices[key]!
                            ? 'Votre version choisie'
                            : 'Version serveur choisie',
                      ),
                    ),
                  const SizedBox(height: 6),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      if (key == 'occupants') {
                        final differences = occupantConflictDifferences(
                          review.localValues[key],
                          review.remoteValues[key],
                        );
                        if (differences != null) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (differences.isEmpty)
                                const Text(
                                  'Aucune différence de valeur entre ces occupants.',
                                ),
                              for (final difference in differences)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        difference.label,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        'Cet appareil : ${difference.local is bool ? (difference.local == true ? 'Oui' : 'Non') : difference.local ?? 'Non renseigné'}',
                                      ),
                                      Text(
                                        'Serveur : ${difference.remote is bool ? (difference.remote == true ? 'Oui' : 'Non') : difference.remote ?? 'Non renseigné'}',
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          );
                        }
                      }
                      if (review.entityType == 'visit_recommendations') {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _recommendationList(
                              'Cet appareil',
                              review.localValues[key],
                            ),
                            const SizedBox(height: 12),
                            _recommendationList(
                              'Serveur',
                              review.remoteValues[key],
                            ),
                          ],
                        );
                      }
                      final local = _value(
                        'Cet appareil',
                        review.localValues[key],
                      );
                      final remote = _value(
                        review.remoteExists
                            ? 'Serveur'
                            : 'Serveur, aucune fiche',
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
              if (selective)
                FilledButton.icon(
                  key: ValueKey('apply-fields-${review.operationId}'),
                  onPressed:
                      _resolving ||
                          _error != null ||
                          !review.localValues.keys.every(choices.containsKey)
                      ? null
                      : () => _resolve(
                          review,
                          true,
                          localFields: {
                            for (final key in review.localValues.keys)
                              if (choices[key] == true) key,
                          },
                        ),
                  icon: const Icon(LucideIcons.check),
                  label: const Text('Valider mes choix'),
                ),
              if (review.entityType == 'patient' &&
                  canRetryOriginalOccupantConflict(
                    jsonDecode(review.payloadJson) as Map<String, dynamic>,
                  ))
                OutlinedButton.icon(
                  onPressed: _resolving || _error != null
                      ? null
                      : () => _retryOriginal(review),
                  icon: const Icon(LucideIcons.refreshCw),
                  label: const Text('Réessayer sans remplacer'),
                ),
              if (!selective)
                OutlinedButton.icon(
                  onPressed: _resolving || _error != null
                      ? null
                      : () => _resolve(review, true),
                  icon: const Icon(LucideIcons.uploadCloud),
                  label: Text(
                    review.remoteExists
                        ? 'Garder ma version'
                        : 'Conserver mes changements et créer la fiche',
                  ),
                ),
              if (review.remoteExists && !selective)
                OutlinedButton.icon(
                  onPressed: _resolving || _error != null
                      ? null
                      : () => _resolve(review, false),
                  icon: const Icon(LucideIcons.downloadCloud),
                  label: const Text('Garder la version serveur'),
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

  Widget _recommendationList(String title, dynamic value) {
    final items = value as List;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title (${items.length})',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (items.isEmpty) const Text('Aucune préconisation'),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SelectableText(
              '${items.indexOf(item) + 1}. ${(item['customTitle']?.toString() ?? '').trim().isNotEmpty ? item['customTitle'] : item['wikiTitle'] ?? 'Préconisation'}\n${item['note'] ?? ''}',
            ),
          ),
      ],
    );
  }

  Widget _value(String title, dynamic value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 14, color: Colors.grey)),
      SelectableText(formatConflictValue(value)),
    ],
  );
}

const _fieldLabels = {
  'caisseRetraitePrincipale': 'Caisse de retraite principale',
  'caissesRetraiteComplementaires': 'Caisses de retraite complémentaires',
  'items': 'Liste des préconisations',
  'firstName': 'Prénom',
  'lastName': 'Nom',
  'phone': 'Téléphone',
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
  'homeHelp': 'Aide à domicile',
  'birthDate': 'Date de naissance',
  'apa': 'Bénéficiaire APA',
  'apaGir': 'GIR',
  'dependenceTxt': 'Aides techniques',
  'note': 'Note',
  'title': 'Titre',
  'name': 'Nom',
  'gender': 'Genre',
  'rdcDesc': 'Pièces au rez-de-chaussée',
  'levels': 'Nombre de niveaux',
  'basement': 'Sous-sol',
  'rdc': 'Rez-de-chaussée',
  'floor': 'Premier étage',
  'secondFloor': 'Deuxième étage',
  'thirdFloor': 'Troisième étage',
  'typology': 'Type de logement',
  'roomsBreakdown': 'Pièces par niveau',
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

String formatConflictValue(dynamic value) {
  if (value == null || value == '') return 'Non renseigné';
  if (value is bool) return value ? 'Oui' : 'Non';
  if (value is List) {
    if (value.isEmpty) return 'Aucun élément';
    return value.map(formatConflictValue).join(' • ');
  }
  if (value is Map) {
    final entries = value.entries.where(
      (e) => !e.key.toString().startsWith('_'),
    );
    if (entries.isEmpty) return 'Non renseigné';
    return entries
        .map(
          (e) =>
              '${conflictFieldLabel(e.key.toString())} : ${formatConflictValue(e.value)}',
        )
        .join('\n');
  }
  return value.toString();
}

String conflictFieldLabel(String key) =>
    _fieldLabels[key] ??
    key
        .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .replaceAll('_', ' ');
