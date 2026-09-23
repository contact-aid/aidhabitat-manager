# Audit de canonicalisation de la synchronisation conditionnelle

## Architecture et cycle

Le serveur lit les lignes NocoDB, les transforme avec les mappers de
server/index.mjs, puis Flutter les persiste dans SQLite. Une édition calcule un
diff dans la même transaction que la création de sync_operations. Le push
renvoie le diff, la baseline capturée et le writeId. Le serveur mappe le souhait
et la baseline vers des colonnes NocoDB, relit la ligne brute, planifie le patch
champ par champ et l'écrit avec un CAS sur Id et app_sync_revision. Une
confirmation ambiguë reste retryable.

| Entité | Lecture et valeurs dérivées | Baseline SQLite | Écriture conditionnelle |
| --- | --- | --- | --- |
| Bénéficiaire | occupants reconstruit depuis les scalaires si le JSON est vide; booléens null lus false; relations lues par libellé | diff partiel; occupants_json stocke la structure exposée | comparaison des occupants contre une vue reconstruite seulement si le JSON brut est vide |
| Dossier | statut d'affichage et beneficiaryPrepared false par défaut | baseline des seuls champs modifiés | enum/libellé canonique; null/false autorisé pour beneficiaire_prepare |
| Logement | cases legacy null lues false; type par libellé; accès rue tri-état | diff partiel; pièces agrégées | cases explicitement listées; relation vide vers null; libellé inconnu diagnostiqué |
| Contexte de vie | sections reconstruites par le protocole de contexte | JSON médical/autonomie, baseline par section | route dédiée et planificateur atomique existant; PUT batch intégré par `1638050` |
| Mesures | nombres texte/nombre normalisés à la lecture | diff scalaire | comparaison Number limitée aux colonnes typées |
| Observations | null exposé comme chaîne vide | diff scalaire | null/chaîne vide seulement sur une liste de textes déclarée |
| Diagnostic sanitaire | tableaux SDB/WC reconstruits depuis les colonnes legacy | tableaux JSON atomiques | vue observée reconstruite puis remappée vers JSON et scalaires avant planification |

## Valeurs fabriquées par les GET

- Structures : occupants, sdbInstances, wcInstances et roomsBreakdown.
- Booléens : les trois indicateurs bénéficiaire, beneficiaire_prepare et une
  liste fermée de cases logement. Les tri-états acces_facile_rue et portes
  SDB/WC sont exclus.
- Relations : situation familiale, statut d'occupation, dépendance, commune,
  type de logement, motorisations et affectation ergo.
- Valeurs d'affichage retirées du contrat : Maison pour une relation absente
  et Modeste pour une catégorie de revenu absente.
- Enums : A visiter, À visiter et TO_VISIT, ainsi que les autres statuts,
  partagent une représentation de comparaison; l'écriture garde les libellés
  NocoDB.
- Représentations techniques : nombre texte/nombre, JSON compact/formaté et
  null/chaîne vide pour des colonnes textuelles explicitement listées.

Un libellé relationnel logement inconnu produit SYNC_RELATION_UNRESOLVED, au
lieu d'une baseline incomplète silencieuse. Les relations bénéficiaire,
notamment Aucune, bénéficient également de la normalisation intégrée sur
`main` par `1638050`.

## Causes et classification

### Faux conflits corrigés

1. occupants_json brut vide face au tableau synthétique du GET.
2. JSON sanitaire brut vide face aux instances synthétiques legacy.
3. Null legacy face à false pour les cases explicitement déclarées.
4. Null face à chaîne vide pour les textes auxquels le GET applique ce défaut.
5. Statut local enum face au libellé NocoDB.
6. Maison et Modeste utilisées comme données source au lieu de valeurs UI.
7. Les builders sanitaires transformaient deux réponses tri-état null en false
   et omettaient wcCuvetteTropHaute du fallback WC.

### Vrais conflits conservés

- Modification concurrente du même occupants_json ou tableau sanitaire.
- Modification concurrente d'un scalaire couplé au JSON sanitaire.
- Null contre false sur un champ tri-état.
- JSON dont l'ordre ou le contenu métier diffère.
- Relation inconnue ou baseline absente.

### Erreurs transitoires

Les 5xx, réponse perdue, révision concurrente pendant le CAS et confirmation
incertaine restent retryables avec le même writeId. Aucun horodatage fraîchement
lu ne rebase la mutation.

### Migrations

Aucune migration de données supplémentaire n'est requise par cette
canonicalisation. Les lignes legacy sont interprétées au moment de la
comparaison. La branche repose désormais sur `1638050`, qui contient les
migrations additives notes/préconisations et la migration SQLite v26.

## Opérations déjà en conflit

Ne jamais les remettre automatiquement à pending. Un outil de recontrôle peut
relire le payload chiffré, conserver baseline et writeId d'origine, puis lancer
le planificateur en lecture seule. Le reclassement est sûr seulement si :

1. toutes les divergences sont des équivalences canoniques connues;
2. expectedUpdatedAt ou la révision prouve que la ligne n'a pas changé;
3. le writeId reste inchangé;
4. aucun champ métier ne figure dans conflictFields.

Sans preuve de version, notamment pour un ancien Maison synthétique face à une
relation vide, l'opération reste en conflit et demande une décision utilisateur.
Cette branche n'implémente aucune reprise automatique.

## Déploiement, validation et retour arrière

1. Vérifier que les migrations additives de `1638050` ont été appliquées avant
   le déploiement applicatif; elles conservent les tables legacy pour le retour
   arrière.
2. Déployer l'API et conserver AIDHABITAT_CONDITIONAL_SYNC=1.
3. Valider sur une copie legacy : date de naissance, case logement, type
   explicite et sanitaire; contrôler le 200, le CAS et la relecture.
4. Sur iPad hors ligne : saisir, fermer, rouvrir, vérifier pending, reconnecter
   et attendre l'acquittement. Tirer ensuite la valeur sur web ou un second iPad.
5. Provoquer un vrai conflit du même champ et une modification indépendante;
   vérifier respectivement le 409 et la fusion préservée.

Retour arrière applicatif : redéployer `1638050`. Ne pas supprimer les colonnes
ou snapshots additifs créés par ses migrations; les anciennes tables sont
conservées. Les opérations pending/conflict restent intactes et ne doivent pas
être forcées.
