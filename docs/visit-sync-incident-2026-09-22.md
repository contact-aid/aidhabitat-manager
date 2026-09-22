# Incident de synchronisation du relevé de visite — 22 septembre 2026

## Symptômes constatés

- Une édition d'autonomie produit un conflit `contexte_de_vie` que l'écran de comparaison ne savait pas rattacher au dossier.
- Une édition WC produit un conflit `diagnostic_sanitaires`; lorsque la fiche distante n'existe pas, l'écran refusait toute comparaison.
- Deux photos ajoutées successivement peuvent lancer deux compressions web simultanées; les octets d'origine étaient dupliqués puis décodés pour les vignettes pendant la compression. Cela peut provoquer un pic mémoire. La cause exacte du plantage observé n'est pas démontrée sans taille/format des fichiers ni profil mémoire du navigateur.

## Correctifs inclus dans la branche

- Le contexte de vie est rattaché au dossier local comme les autres sous-fiches.
- La comparaison des sous-fiches distingue une réponse absente d'une lecture impossible. Seule l'option de création conditionnelle permet de conserver une saisie locale quand le serveur n'a pas encore de ligne; aucune suppression locale implicite.
- Une création conditionnelle envoyée à un serveur non préparé rend 503 (réessayable) au lieu d'un 428 classé à tort comme conflit métier.
- L'import des photos d'un même onglet est séquentiel, sans copie supplémentaire des octets choisis et sans décodage de l'image brute pour le placeholder.

## Prérequis bloquant de mise en production

Le protocole `contexte_de_vie` et les créations conditionnelles des quatre sous-fiches requièrent la migration et les drapeaux décrits dans [sync-context-atomic-2026-09-17.md](sync-context-atomic-2026-09-17.md). Le client actuel ne peut pas synchroniser ces opérations avec garantie de concurrence tant que `AIDHABITAT_CONDITIONAL_SYNC` n'est pas activé sur une base préparée, et `AIDHABITAT_UNIQUE_CHILDREN_READY` sur des contraintes d'unicité vérifiées. Ces drapeaux ne doivent **pas** être activés simplement pour faire disparaître le bandeau: sauvegarde, inventaire des files locales, vérification de schéma/index, test en staging et coordination des clients sont requis. Aucune opération existante ne doit être abandonnée, ni le cache local effacé.

## Vérification

- Tests de conflit local: contexte, mesures, observations et sanitaires; absence distante, comparaison sans mutation, création conditionnelle.
- Tests HTTP serveur: création conditionnelle non préparée sans écriture et CAS atomique préparé.
- Tests Flutter complets, analyse statique, tests serveur et contrats de synchronisation.
- Reste à réaliser avant activation: contrôle de préparation de la base réelle en lecture seule, test en staging avec deux appareils, puis vérification du dossier de démonstration sans toucher à ses saisies en attente.
