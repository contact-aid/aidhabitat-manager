# Fusion prudente et choix lisibles, candidat 98

Après le build 97, les anciennes opérations de l’iPad restent conservées. La correction `levels` permet de lire la comparaison, mais ne décide pas à la place de l’ergothérapeute pour une ancienne liste dont la référence manque.

## Comportement

- Un champ serveur vide et identique à la référence autorise le remplissage local. `null` et chaîne vide représentent une même absence de valeur ; zéro et faux restent des valeurs.
- Les valeurs identiques et les modifications indépendantes peuvent être reprises automatiquement. Les bénéficiaires utilisent aussi la référence du formulaire ouvert ; les informations indépendantes d’un même occupant sont conservées si son identité est restée stable.
- Deux modifications incompatibles, un effacement concurrent ou une référence absente restent à vérifier. Le chemin de reprise des bénéficiaires ne choisit plus systématiquement la saisie locale.
- Le logement et le dossier peuvent être résolus champ par champ. La décision est enregistrée dans la transaction locale avec la mutation d’origine et les valeurs serveur. Le nouvel envoi conserve un contrôle de version serveur.
- Une fenêtre présente les valeurs et les choix « Garder ma version », « Garder la version serveur » et « Décider plus tard ». Les listes de pièces sont lisibles sans JSON ni identifiants internes. Le bandeau et la liste des conflits utilisent des termes compréhensibles ; le nom du dossier est chargé localement.

Les protocoles spécialisés de notes, médias, préconisations et sections structurées ne sont pas remplacés par une politique générale « dernier arrivé gagnant ». Les anciennes collections restent soumises à un choix explicite. Aucun effacement de file, aucune modification directe de NocoDB ni migration de schéma.

## Validation

- 878 tests critiques Flutter réussis après la modification des attentes qui imposaient auparavant une priorité locale sur un vrai conflit.
- Contrats de synchronisation et contrôles des flux critiques réussis.
- Tests de fenêtre à 390 et 1024 pixels, annulation sans écriture, double clic, comparaison indisponible et décision périmée.
- Test SQLite : choix mixte du logement, restauration des seuls champs choisis sur le serveur, copie des deux versions dans l’historique, écriture locale en attente d’acquittement.

## Livraison et recette

Candidat 1.0.0+98. La recette physique et la diffusion restent à consigner. L’application isolée de test utilise un identifiant de bundle distinct et uniquement un dossier fictif ; elle ne remplace pas App’Ergo et n’appelle aucun serveur réel. Ce test ciblé ne constitue pas à lui seul la recette complète du dossier témoin décrite dans `protocole-version-stable.md`.
