# Notes anciennes : réparation ciblée de l’identité de synchronisation

Base : web/API 71, b7d054d6288b40d1f9af3df328357f4ce8a839de.

## Défaut reproduit

Une note ancienne peut avoir scope_id=patientId, dossier_id=dossierId.
Les lectures locales conservent sa révision mais pas son scope. Une sauvegarde
qui infère scope_id=dossierId obtient NOTE_PAGE_RECORD_MISSING, même lorsque
la révision distante n’a pas changé. Le message « deux versions » est alors faux.
La saisie d’un texte commun à plusieurs pages réenregistre chaque page ; elle
explique plusieurs conflits simultanés, sans nécessiter plusieurs appareils.

## Correction client

- Seulement après NOTE_PAGE_RECORD_MISSING : lecture authentifiée de la page
  sous scope_id=patientId. Il faut une seule page, même patient, dossier,
  scope_type, onglet, sous-onglet vide, numéro et révision attendue.
- La révision égale à notre writeId permet aussi de rejouer un ACK perdu ; le
  serveur doit toujours vérifier le payload complet avant tout acquittement.
- Réessai avec la même révision attendue et le même writeId, vers le scope
  réellement observé. Pas de création, changement de clé distante ou rebase.
- Les notes indépendantes canonicalisées au dossier sont exclues de ce pont.
- Conflits déjà enregistrés : bouton « Vérifier et réessayer », sans choix de
  version. Une nouvelle lecture est requise. Transaction locale compare writeId,
  identité et dessin en file avec dessin local. Seule l’adresse de la mutation
  change ; textes, dessin, preview, révision et writeId restent identiques.
- Une autosauvegarde ultérieure conserve l’adresse corrigée pour ce dossier.
- Les erreurs 409/428 conservent leur code et requestId dans le diagnostic sans
  exporter le contenu clinique. Les autres vrais conflits restent à comparer.

## Limites et publication

Ce correctif n’est pas le stockage fractionné 413. Aucun code serveur, aucune
migration NocoDB ni reprise de dossiers ; aucun build ou installation iPad.
Les clients déjà installés restent inchangés jusqu’à une mise à jour.
Les quatre opérations du navigateur utilisateur ne sont pas déclarées résolues
avant recette après publication. Ne pas vider la file ni choisir une version
pour contourner le défaut. Si l’identité ou la révision n’est plus prouvée, la
réparation refuse et conserve le conflit. Aucun changement distant concurrent
n’est écrasé par ce pont : le contrôle de révision serveur reste obligatoire.
Le pont de compatibilité peut ajouter une lecture et un nouvel envoi pour une
ancienne identité ; il ne migre pas les notes en masse.
