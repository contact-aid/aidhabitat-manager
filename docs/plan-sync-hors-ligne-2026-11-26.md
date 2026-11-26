# Plan de correction de la synchronisation iPad, serveur et web

Date : 26/11/2026. Statut : proposition, aucun code modifié.
Règle de départ (décision du 06/11) : quand un même champ est modifié sur l'iPad et sur le web, la vraie heure de saisie gagne, et la valeur perdante est archivée, jamais détruite.

## Objectif

- Plus de fenêtre « version locale ou version serveur » dans l'usage normal.
- Plus aucune perte silencieuse : chaque valeur écrasée est retrouvable et restaurable.
- iPad : travail hors ligne complet en visite, envoi automatique au retour du réseau.
- Web : application en ligne, qui écrit directement sur le serveur et affiche toujours la version à jour.

## Règle absolue pendant tout le chantier : zéro perte sur les dossiers en cours

Ces règles s'appliquent à chaque étape, sans exception :

1. **Jamais de vidage** de la file `sync_operations`, du cache local, de `sync_conflict_history` ou des données du navigateur. Pas de « réinstaller l'app » pour régler un problème.
2. **Sauvegarde NocoDB complète** (`tools/backup-nocodb.mjs`) avant chaque déploiement serveur, avec vérification que la sauvegarde se relit.
3. **Changements additifs uniquement** : nouvelles colonnes et nouvelles tables. Aucune colonne supprimée ou renommée, aucune donnée réécrite en masse sans script testé en staging et relu.
4. **Compatibilité ascendante** : le serveur continue d'accepter l'ancien format d'envoi (version 1) tant qu'un appareil peut encore en avoir dans sa file. Une saisie faite hors ligne avec l'ancien build doit passer après la mise à jour.
5. **Ordre de déploiement** : serveur d'abord, puis iPad, puis web. Jamais l'inverse.
6. **Pas de déploiement pendant une journée de visites.** Chaque iPad est synchronisé et sa file vérifiée vide (ou ses conflits exportés) avant l'installation d'un nouveau build.
7. **Staging d'abord** (`docs/appergo-nocodb-staging.md`), avec les scénarios de test listés plus bas, avant la production.
8. **Retour arrière prévu** : chaque étape doit pouvoir être désactivée par un indicateur serveur, sans perte des données écrites entre-temps.

## Étape 0 : état des lieux et protection (avant tout code)

But : savoir exactement ce qui est en attente aujourd'hui, et ne rien perdre au démarrage.

- Sauvegarde NocoDB complète.
- Inventaire de chaque iPad et de chaque navigateur utilisé : nombre d'envois en attente, en échec et en conflit (diagnostic déjà présent dans la fenêtre du compte). On note les dossiers concernés.
- Pour chaque conflit en cours : export du contenu (valeur locale et valeur serveur) avant toute résolution. On résout ensuite à la main, dossier par dossier, avec toi.
- Relevé des journaux serveur `[sync-conflict]` sur deux semaines : quel type de conflit, sur quels champs. Ce relevé confirme l'ordre des causes et servira de point de comparaison après correction.

Risque de perte : nul (lecture seule).

## Étape 1 : archive serveur des valeurs écrasées (le filet de sécurité)

But : arrêter tout de suite les pertes silencieuses, avant de changer la moindre règle.

- Nouvelle table NocoDB `sync_archive` : dossier, table, champ, valeur écrasée, nouvelle valeur, heure de saisie connue de chaque côté, appareil, utilisateur, identifiant d'envoi (`writeId`), date d'archivage.
- Le serveur y écrit une ligne **à chaque fois qu'un envoi remplace une valeur différente** de celle de départ de l'appareil. Cela couvre le mode actuel, où l'iPad écrase les champs simples et les sections du contexte de vie ([server/index.mjs:524](../server/index.mjs:524), [server/contextGuardedSync.mjs:372](../server/contextGuardedSync.mjs:372)).
- L'écriture dans l'archive se fait **avant** l'écriture de la nouvelle valeur. Si l'archive échoue, l'envoi est refusé de façon temporaire (réessai automatique) et n'écrase rien.
- Envoi vers le serveur des `sync_conflict_history` déjà stockés sur chaque iPad, pour centraliser l'historique existant.
- Écran simple (web, accès admin) : liste des valeurs archivées par dossier, avec un bouton « restaurer ».

Risque de perte : nul. On ajoute une copie, on ne change pas le comportement.

## Étape 2 : heure de saisie par champ, avec horloge corrigée

But : appliquer ta règle (la vraie heure gagne) sur les champs simples et le contexte de vie.

Côté iPad :
- Chaque saisie enregistre l'heure de modification **de chaque champ** (pas de la ligne).
- Écart d'horloge : à chaque réponse du serveur, l'app mesure l'écart entre son heure et `serverTime` (déjà renvoyé par l'API). L'heure envoyée est corrigée de cet écart. Si aucun écart n'a été mesuré depuis le démarrage (iPad démarré hors ligne), on utilise le dernier écart connu, mémorisé en local.
- Nouveau format d'envoi (version 2) : il contient en plus `fieldEditedAt` (heure corrigée par champ). Le format 1 reste accepté.
- Les envois déjà en file au moment de la mise à jour : l'app leur attribue l'heure de création de l'opération en file, qui est l'estimation la plus prudente.

Côté serveur :
- Nouvelle colonne par table synchronisée : `app_field_clock_json` (heure de la dernière modification retenue, par champ). Additive.
- Pour chaque champ reçu : si l'heure reçue est plus récente que l'heure stockée, on écrit, et l'ancienne valeur part dans l'archive. Sinon, on garde la valeur serveur, la valeur reçue part dans l'archive, et la réponse est un **succès** qui renvoie la valeur gagnante. L'iPad met alors sa copie locale à jour, sans conflit ni fenêtre.
- Égalité exacte d'heure : le serveur garde la valeur déjà en place et archive l'autre.
- Envoi au format 1 (ancien build) : comportement actuel, mais avec archive (étape 1).
- Les écritures qui ne viennent pas des apps (synchro Airtable, n8n, génération de rapport) mettent aussi à jour l'heure des **seuls champs qu'elles modifient**. Une synchro Airtable qui change le statut ne doit plus faire « gagner » le serveur sur la date de naissance.

Contexte de vie : les sections médical et autonomie sont découpées en champs, et chaque champ suit la même règle. On ne remplace plus une section entière.

Risque de perte : faible, et toute valeur perdante est archivée. Point de vigilance : un iPad avec une horloge très fausse. Si l'écart mesuré dépasse 10 minutes, l'app l'affiche dans le diagnostic.

## Étape 3 : listes fusionnées élément par élément

But : supprimer la première cause de conflits (occupants, pièces, salles de bain, WC).

- Pièces par niveau, salles de bain et WC ont déjà un identifiant stable (`id`, `instanceId`). Le serveur fusionne élément par élément, puis champ par champ dans chaque élément, avec la règle de l'étape 2.
- **Occupants : ils n'ont pas d'identifiant** et sont repérés par leur position dans la liste ([models/dossier_occupants.dart](../aid_habitat_app/lib/models/dossier_occupants.dart)). C'est la partie la plus délicate :
  1. Script de migration, testé en staging puis lancé après sauvegarde : il attribue un identifiant à chaque occupant existant, sans changer l'ordre ni le contenu. Contrôle avant/après sur chaque dossier.
  2. Les nouveaux builds créent un identifiant à chaque ajout d'occupant.
  3. Un envoi d'ancien build (sans identifiant) n'est fusionné que si la liste serveur n'a pas changé depuis son point de départ. Sinon, sa version complète de la liste part dans l'archive, et le dossier est signalé « à vérifier ». Rien n'est écrasé.
- Suppressions : un élément supprimé est marqué « supprimé à telle heure » au lieu de disparaître de la liste. Une modification plus récente sur un élément supprimé le fait réapparaître, et la suppression est archivée.
- Ordre des éléments : il est stocké à part, avec sa propre heure, et ne crée jamais de conflit.

Risque de perte : moyen pendant la migration des occupants. D'où la sauvegarde, le staging, le contrôle dossier par dossier et le refus d'écraser en cas de doute.

## Étape 4 : notes sans fenêtre de choix

But : ne plus bloquer une page de notes modifiée des deux côtés.

- Le serveur garde le contenu de la dernière version reconnue par chaque appareil (sa « base »).
- Si la page a changé des deux côtés : fusion automatique du texte quand les modifications ne se chevauchent pas (passages différents de la page).
- Si elles se chevauchent : on garde les deux. La version la plus récente reste en place, et l'autre est ajoutée à la fin de la page dans un bloc daté (« Version iPad du 26/11 à 10 h 12 ») et copiée dans l'archive. Tu supprimes le bloc quand tu as vérifié.
- Dessins à main levée : pas de fusion possible. Le plus récent reste en place, l'autre est archivé et restaurable.

Risque de perte : nul. Au pire, un texte en double dans la page.

## Étape 5 : lecture serveur plus fine sur l'iPad

But : que l'iPad voie les modifications du web même quand un envoi est en attente sur le dossier.

- Le pull ne saute plus le dossier entier ([dossier_repository.dart:1158](../aid_habitat_app/lib/services/dossier_repository.dart:1158)). Il met à jour tous les champs **qui ne sont pas en attente d'envoi**, et laisse intacts ceux qui le sont.
- Le conflit « la fiche locale a changé pendant que le formulaire était ouvert » ([dossier_repository.dart:2749](../aid_habitat_app/lib/services/dossier_repository.dart:2749)) est remplacé par la règle de l'heure par champ.
- Le conflit local créé quand une réponse s'est perdue en route ([nocodb_sync_service.dart:426](../aid_habitat_app/lib/services/nocodb_sync_service.dart:426)) disparaît. Avec l'identifiant d'envoi et l'heure par champ, renvoyer un envoi déjà reçu est sans danger.
- Lecture serveur aussi à l'ouverture d'un dossier quand le réseau est là, pas seulement au démarrage et au retour au premier plan.

Risque de perte : faible. Les champs en attente ne sont jamais touchés par le pull.

## Étape 6 : web en ligne, sans file locale

But : le web montre toujours la version serveur et écrit directement dessus.

La web app a aujourd'hui sa propre file d'attente dans le navigateur. **Elle peut contenir des saisies non envoyées.** D'où trois temps :

1. **Build web « vidange »** : il envoie tout ce qui reste dans la file du navigateur, n'ajoute plus rien à cette file, et affiche un message clair si un envoi échoue (avec un export du contenu). On vérifie que la file est vide sur chaque poste utilisé.
2. **Build web « direct »** : chaque enregistrement va directement au serveur. En cas de coupure, la saisie reste dans le formulaire avec le message « non enregistré, réessayer », jamais perdue en silence. Le brouillon est aussi gardé dans le navigateur jusqu'à confirmation du serveur.
3. Relecture du dossier à son ouverture, au retour sur l'onglet et après chaque enregistrement.

Risque de perte : nul si l'étape 1 de vidage est respectée sur chaque poste avant l'étape 2.

## Étape 7 : retrait de la fenêtre de choix

- Seulement quand le relevé `[sync-conflict]` montre zéro conflit pendant au moins deux semaines d'usage réel, dont des visites hors ligne.
- La fenêtre est remplacée par l'historique des versions archivées, consultable par dossier, avec restauration.
- Le bandeau rouge ne reste que pour les vraies pannes (serveur injoignable longtemps, envoi refusé pour droits).

## Scénarios de test obligatoires (staging, puis production sur un dossier de test)

1. Visite hors ligne de 3 h sur l'iPad pendant que le web modifie d'autres champs du même dossier : tout est fusionné, aucune fenêtre.
2. Même champ modifié sur le web à 14 h et hors ligne sur l'iPad à 10 h, envoyé à 16 h : la valeur du web reste, celle de l'iPad est archivée.
3. Même chose dans l'autre sens (iPad à 15 h, web à 14 h) : l'iPad gagne, la valeur du web est archivée.
4. Réseau qui coupe pendant un envoi, puis nouvelle saisie : aucun doublon, aucun conflit.
5. Ajout d'un occupant sur le web, correction d'un autre occupant sur l'iPad hors ligne : les deux sont gardés.
6. Suppression d'un occupant sur un appareil, modification du même occupant sur l'autre : la règle de l'heure s'applique, et l'autre version est archivée.
7. Note modifiée des deux côtés à des endroits différents : fusion. Au même endroit : les deux versions sont présentes.
8. iPad avec une horloge en avance de 2 h : la correction d'écart s'applique et le diagnostic le signale.
9. iPad sur l'ancien build avec des saisies en file, puis mise à jour : tout passe, sans perte.
10. Synchro Airtable pendant une visite hors ligne : elle ne fait perdre aucune saisie iPad sur d'autres champs.
11. Onglet web ouvert toute la journée : il affiche la version à jour après retour sur l'onglet.

Chaque scénario est rejoué avec contrôle de l'archive : la valeur perdante doit y être.

## Ordre et taille indicative

| Étape | Contenu | Taille | Dépend de |
|---|---|---|---|
| 0 | État des lieux, sauvegarde, export des conflits | petite | rien |
| 1 | Archive serveur | moyenne | 0 |
| 2 | Heure par champ et contexte de vie | grosse | 1 |
| 3 | Listes élément par élément, identifiants des occupants | grosse | 2 |
| 4 | Notes | moyenne | 1 |
| 5 | Pull fin sur l'iPad | moyenne | 2 |
| 6 | Web en ligne (vidange puis direct) | moyenne | 2 |
| 7 | Retrait de la fenêtre | petite | toutes |

Les étapes 0 et 1 apportent déjà la sécurité principale (plus aucune perte silencieuse) et peuvent partir rapidement.

## Décisions à prendre avant de coder

1. **Web en ligne uniquement** : d'accord pour retirer la file locale du web ?
2. **Notes qui se chevauchent** : garder les deux versions dans la page (proposé), ou seulement dans l'archive ?
3. **Suppression contre modification** d'un même élément de liste : la plus récente gagne (proposé), ou la suppression gagne toujours ?
4. **Accès à l'archive et à la restauration** : toi seul, ou chaque ergothérapeute pour ses dossiers ?
5. **Seuil d'alerte d'horloge** : 10 minutes proposé.
6. **Période sans visite** pour chaque déploiement : quels créneaux ?
