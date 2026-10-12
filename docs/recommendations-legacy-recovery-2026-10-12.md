# Récupération des conflits de préconisations

Le message « Cette préconisation a été mise en attente par une ancienne version de l’application » est déclenché par une opération locale sans enveloppe de publication. Ce message ne prouve pas que deux personnes ont modifié le dossier simultanément.

Deux défauts sont corrigés :

- La comparaison des conflits ne chargeait pas les préconisations. Elle charge maintenant la liste locale et le snapshot serveur avec sa révision.
- L’acquittement d’une nouvelle fiche bibliothèque pouvait créer une publication au format historique. Les nouvelles publications portent désormais une enveloppe atomique avec la révision connue. Une révision inconnue reste une création conditionnelle, jamais une écriture forcée.

Le choix explicite conserve la liste locale ou adopte la liste serveur en préservant les brouillons locaux, y compris les fiches `local_draft_`. La décision, la saisie et la révision examinées sont archivées dans l’historique local chiffré. Une modification survenue après l’ouverture de la comparaison ou une autre opération en attente invalide le choix. Le serveur continue de refuser une publication si sa révision a changé entre la comparaison et l’envoi.

Les anciennes opérations sans enveloppe ne peuvent plus être résolues automatiquement par comparaison des dates. Les dates ne suffisent pas à décider quelle saisie garder.

## Reprise sur l’appareil concerné

Après publication du correctif :

1. Charger la nouvelle version de l’application dans le navigateur qui conserve la saisie bloquée.
2. Ouvrir **Détails** dans le bandeau de synchronisation, puis l’opération de préconisations.
3. Comparer les listes **Cet appareil** et **Serveur**. Choisir **Conserver mes changements** si la liste locale est celle du rapport souhaité.
4. Attendre la confirmation de synchronisation, puis relancer la génération du PDF.

Les données locales doivent rester disponibles pendant la reprise. Ce correctif ne résout pas à distance une saisie conservée uniquement dans le navigateur d’une autre personne.

## Validation

- 101 tests ciblés passent : publication, remappage wiki, conflits secondaires, récupération historique, comparaisons à 390 et 1024 pixels.
- Analyse Dart des fichiers concernés : aucune anomalie.
- Compilation Flutter web de production : réussie (avertissements Wasm de dépendances déjà présentes).
- Deux goldens historiques échouent sur 4 et 8 pixels dans cet environnement. Le même écart est reproduit avec le fichier d’écran original, avant ce correctif. Les images de référence restent inchangées.

Le candidat est basé sur `codex/fix-voice-dictation` pour conserver les corrections du candidat web 79. Aucune donnée de production ni aucune saisie du navigateur concerné n’a été modifiée pendant ce diagnostic.
