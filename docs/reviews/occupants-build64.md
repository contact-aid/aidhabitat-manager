# Occupants — décision du candidat web 69

Base publiée : `cc9b7ccedf1e0bf0e0eb97d9eb12e7d03a3fc470` (web 68).
Client iPad exact : `a5b4d9fbe40579160a9290688a7707e7a3376c2c` (64).

## Retenu

- Présentation d'une ligne par occupant dans la fiche dossier en lecture, civilité connue (M./Mme.), inconnue vide, nom de naissance déjà stocké.
- Titres Bénéficiaire(s), Occupant(s) et en-tête avec prénoms regroupés lorsque le nom est partagé.
- Projection uniquement visuelle des deux identités anciennes certaines : deux prénoms simples distincts joints par « et »/« & » avec un nom et un foyer de deux personnes, ou deux noms complets dont le même nom de famille est répété en majuscules.
- Les identités structurées existantes priment sur les colonnes anciennes en cas de contradiction. La valeur d'origine est affichée dans un signalement pour les cas ambigus. Aucune inférence du genre à partir d'un prénom.
- `maidenName` devient lisible et conservé par `Occupant.fromJson/toJson/copyWith` : absence reste absence, effacement `''` reste vide. Aucun contrôle permettant de saisir ce champ ajouté ici.
- Les projections ne sont jamais passées au repository. La fiche garde son formulaire existant : pas de nouveau bouton d'ajout/retrait ni de nouveau formulaire multi-occupants dans ce candidat.

## Écarté

La nouvelle ligne éditable Nom/Prénom/Civilité par occupant, l'ajout/retrait avec confirmation, la saisie du nom de jeune fille, la conversion persistée des noms regroupés et la nouvelle reprise du genre Airtable sont différés. Le code local historique correspondant n'est pas importé. L'API/Airtable et les données réelles ne sont pas modifiés pour ce lot.

Motif démontré et non simple supposition : le modèle 64 élimine `gender` et `maidenName`. Sa protection serveur actuelle les récupère sur identité unique, mais ne protège pas la composition de la liste. L'onglet Bénéficiaire reconstruit exactement `numberPeople` entrées ; une liste de trois avec nombre ancien deux est sauvée avec seulement deux entrées lors d'une saisie de santé. Un iPad hors ligne ayant connu seulement Alice peut renvoyer une liste d'une personne après ajout de Bob sur le web : la vraie route HTTP accepte cette écriture malgré la baseline, et Bob disparaît dans le NocoDB simulé. Ces tests verts sont des **preuves de défaut**, pas une validation de la saisie multiple.

## Preuves reproductibles (données fictives uniquement)

- `bash tools/test-build64-occupants.sh` : export git immuable de 64, modèle réel et widget Bénéficiaire réel ; trois tests (champs inconnus éliminés, nombre périmé tronqué, nombre cohérent conservé). Aucun binaire iPad construit.
- `node --test server/occupantsBuild64Compatibility.test.mjs` : vraie application Express, authentification fictive et NocoDB REST simulé, connexions externes interdites. Identité stable : genre/nom de naissance conservés ; baseline périmée : occupant perdu ; effacement web puis écriture legacy sans ces champs : pas de réapparition.
- Tests `dossier_occupants_test.dart`, `occupant_maiden_name_test.dart`, `dossier_occupants_display_test.dart` : noms simples/ambiguïtés/conflits, pluriel, civilités, modèle, ouverture/réouverture sans sauvegarde.
- `occupants_display_storage_test.dart` : vraie SQLite fictive, pas de conversion du JSON au chargement/réouverture, modification hors ligne du téléphone ne transmet aucun occupant ni identité déduite.

## Prérequis de la fonctionnalité complète

Un futur client iPad doit préserver tous les occupants indépendamment du nombre ancien, transmettre les champs qu'il ne modifie pas sans les perdre, et distinguer explicitement ajout/retrait/effacement. Le serveur doit aussi arbitrer les listes concurrentes par identité stable et suppressions explicites ; la priorité automatique à la sauvegarde locale n'est pas suffisante. Refuser toutes les anciennes écritures sans parcours de récupération laisserait les saisies hors ligne bloquées : ce n'est pas une solution validée.

Il faut ensuite rejouer web → iPad hors ligne → web, renommages, ajout/retrait concurrent et effacements avec les clients concernés, puis une recette physique. Aucun appareil, aucun dossier réel ni migration n'a été utilisé ici. Les PDF réels des visites restent non validés.
