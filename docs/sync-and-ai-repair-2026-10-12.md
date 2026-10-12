# Synchronisation des occupants et prompt de reformulation

## Cause reproduite

Une liste d’occupants sauvegardée avant l’ajout des champs de détails peut omettre `apaDetails`, `invalidityDetails`, `fiscalReferenceYear` ou `apaGir`. Le formulaire représente ces champs vides par une chaîne vide et le revenu absent par `fiscalRevenue: null`. La comparaison de listes entières considérait ces représentations comme différentes.

Un scénario HTTP réel avec des identités fictives reproduit un HTTP 409 `SYNC_FIELD_CONFLICT` lors du passage APA de faux à vrai. La normalisation ciblée de ces valeurs permet désormais cette écriture avec le contrôle de révision existant. La même équivalence est appliquée aux contrôles de modification du formulaire et au plan de comparaison côté Flutter.

Les différences non vides, les revenus nuls versus zéro, les champs inconnus, l’ordre des personnes, les changements de composition et les modifications concurrentes réelles restent distincts. Le correctif ne donne aucune priorité automatique à une version et ne retire pas les contrôles de compte ou d’identité. Toutes les situations de conflit ne peuvent pas être supprimées : deux modifications incompatibles doivent encore être arbitrées.

## Reprise des conflits existants

L’écran affiche les différences de valeur par personne lorsque les identités uniques et leur ordre correspondent : par exemple APA, Oui sur cet appareil et Non sur le serveur. Les champs vides équivalents sont masqués. Une composition ambiguë ou réordonnée conserve la comparaison complète.

« Réessayer sans remplacer » est disponible pour une mutation moderne d’occupants, avec référence originale et erreur serveur de comparaison. Il remet seulement cette opération en attente, après contrôle de son instantané et de son auteur. Le contenu, la référence, l’identifiant d’écriture et le propriétaire sont conservés. Le serveur décide à nouveau si elle peut être appliquée. Une vraie divergence reste bloquée. Les mutations anciennes sans contrat de collection et les conflits de formulaire périmé ne sont pas repris par ce bouton.

Aucune file utilisateur n’est lue, supprimée ou réécrite pendant le développement. Un conflit déjà présent sur un appareil doit être repris depuis cette fenêtre après la mise à jour.

## IA

Le prompt navigateur précédent privilégiait les plus petites modifications et ne connaissait pas la rubrique. Le nouveau prompt partagé avec l’API demande de corriger toutes les fautes, puis de reformuler les tournures maladroites pour un rapport d’ergothérapeute. Il conserve les phrases claires, les faits, noms, valeurs, négations et incertitudes ; il interdit d’inférer une cause absente.

La rubrique est une valeur fermée : bénéficiaire, contexte de vie, médical, autonomie, aides humaines, logement ou préconisations. Elle suit la note dans son affichage normal et agrandi. Les titres arbitraires ne deviennent pas des instructions système. Le canal Apple reçoit également cette rubrique ; seule sa syntaxe Swift et le transport Flutter sont vérifiés ici, sans publication native.

Une sortie identique est annoncée comme « L’IA n’a proposé aucune modification », avec une possibilité de réessayer. Cela ne prouve pas que la note est déjà correcte. La proposition reste modifiable et doit être relue.

## Validation

- 462 tests serveur réussis, incluant les routes Express conditionnelles et leurs scénarios de concurrence.
- 767 tests critiques Flutter réussis, puis les tests supplémentaires de transport du contexte et de comparaison d’écran.
- Tests du nouveau retry : conservation exacte des données et de la référence, refus d’un instantané périmé, rollback sous un autre compte.
- Tests de valeurs : champs vides équivalents, APA différente, zéro distinct d’absence, détails non vides, personnes ambiguës et réordonnées.
- 37 tests du moteur navigateur ; build web de production réussi.
- Analyse Flutter ciblée sans anomalie ; syntaxe Swift vérifiée.
- Essais de génération dans Firefox avec le worker de production et des notes exclusivement fictives. Aucun texte de bénéficiaire réel utilisé pour les essais.

Le moteur et ses poids restent identiques. Ce correctif de prompt ne garantit pas une génération sous cinq secondes et ne déploie pas de moteur privé sur le VPS.
