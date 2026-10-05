# Assist 2 — interface complète, 5 octobre 2026

## Isolation et intégration

Base convenue Main : `150b555ca2c26a0869ae9e34fa4892c68df944ac` (web 69 et correctif récupération).
Worktree : `/Users/aidhabitat/.codex/worktrees/appergo-assist2-full-ui/aid'habitat-manager`.
Branche : `codex/appergo-assist2-full-ui-20261005`.
Aucune modification du checkout principal, version, production ou installation iPad.
Les dépendances Main/Assist 1 ci-dessous ont été reprises par cherry-pick, sans édition de leurs fichiers.

## Commits Assist 2 à intégrer dans cet ordre

| Commit | Fichiers / portée |
| --- | --- |
| `72cfef1` | documents_screen, service/test mandats et 6 fonds PNG, scanner Swift/service/test, dictée bouton/runtime/bridge JS et test JS |
| `f383546` | notes_widget, visit_report_screen, dossier_refresh_preview_dialog et leurs tests ; notes indépendantes et politique stylet iOS |
| `72c4f0b` | beneficiary_tab et tests sauvegarde/nom de jeune fille ; conserve Civilité et ajoute sélection de plusieurs aides |
| `d6c2cce` | service/test mandats : préserver les imports historiques sans identifiants automatiques |
| `67b46aa` | accessibility_tab, bathroom_tab, wc_tab, sanitary_room_links, tests sanitaires/accessibilité et script exact64 |
| `477ee91` | visit_report_screen et typography_layout_test : actions sur plusieurs lignes |
| `dfdebfa` | service/test mandats : ID déterministe par dossier et SHA256 de l'e-mail normalisé |
| `82d2c9e` | test/compat/mobility_build64_test.dart et tools/compat/test-mobility-build64.sh : séparer preuve64 et attentes du client actuel |
| `99ee396` | independent_notes_widget_test : attente SQLite bornée compatible avec les transactions et FakeAsync |
| `2f94e98` | interfaces sanitaires/helper et tests : niveaux supérieurs normalisés, aucun lien ordinal ambigu, ancienne liste illisible préservée et signalée |
| `b557112` | plan_canvas, plans_tab et 2 suites : création/duplication, identités stables, dessin et navigation du canvas |
| `bf0644c` | accolades explicites des gardes de préservation des mandats |

Dépendances originales reçues : Assist 1 `f7bb283`, `b03c680`, `f47b18f`, `d4d34d7`, `1cd9e09`, `cb5d306` ; Main `8a48d8e`.
Main intègre séparément le correctif serveur mandats `1080038` et sa validation d'identité dans la route.
Ne pas dupliquer les cherry-picks de ces dépendances déjà présentes dans l'intégration.

## Préservation et fonctionnement

- Sanitaires : les instances enregistrées restent dans leur ordre avec leurs identifiants et leurs libellés. Une forme vide pour une nouvelle pièce n'est enregistrée qu'après modification explicite. Une suppression volontaire du logement cible uniquement les diagnostics liés aux identifiants retirés. Les nombres ambigus ne permettent aucune association ou suppression automatique. Les niveaux `second_floor`/`secondFloor` et `third_floor`/`thirdFloor` partagent leurs identités legacy.
- Plans : aucun décalage de contenu entre numéros. Lecture exhaustive sans plafond 100 et sans arrêt au premier trou ; duplication complète via API Assist 1 vers max+1. Les métadonnées JSON anciennes restent présentes lors du premier trait. Les grands plans restent accessibles après passage à un écran plus petit. Un chargement périmé ne remplace plus la page sélectionnée.
- Page vide indépendante : `pageKind: blank` et phase nulle. Scénario : repart du dessin avant travaux. Rectangle fixé après tracé ; équipements sélectionnables ; main et pincement ; contacts de paume simulés ne suppriment pas le trait Pencil actif.
- Les anciens plans image ou de format inconnu restent en lecture seule. Leur duplication conserve le contenu ; l'API refuse une duplication raster sans aperçu disponible plutôt que produire un document incomplet.
- Suppression des pages de plans désactivée avec explication dans le menu, conformément à la décision Main : aucun tombstone anti-résurrection64 suffisamment vérifié n'est livré.
- Mandats : modèles fournis Coralie/Christelle et modèle générique, adresse commune et téléphone de l'intervenant laissé vide. Six pages fictives rendues et inspectées ; superpositions des libellés téléphone/adresse/raison sociale corrigées. Anciens mandats reconnus par titre/nom/tag, sans remplacement. L'ID repose sur l'e-mail normalisé pour rester identique entre appareils.
- Les fichiers de navigation déjà livrés en69 ont été conservés. Les services/modèles/serveur partagés restent sous propriété Main/Assist 1.

## Vérifications exécutées

Toutes les données utilisées sont fictives. Flutter exécuté sur copie isolée sous `/tmp/assist2-full-ui-tests/aid_habitat_app_test_safe`, afin d'éviter le problème des chemins contenant une apostrophe.

- Bundle de 18 fichiers Flutter : **120/120**. Log `/tmp/assist2-ui-final-tests.log`.
- Après ajout du cas paume pendant Pencil : suite canvas **6/6** (5 cas déjà dans le bundle et 1 cas nouveau). Log `/tmp/assist2-final-pencil-tests.log`.
- Analyse Flutter finale : **aucun problème**. Log `/tmp/assist2-ui-final-analyze.log`.
- Pont dictée JS : **12/12**, `node tools/test-voice-speech-bridge.mjs`.
- Syntaxe Swift : `xcrun swiftc -frontend -parse aid_habitat_app/ios/Runner/DocumentScannerPlugin.swift` réussie. Ce n'est pas un build iPad.
- Code exact build64 `a5b4d9fbe40579160a9290688a7707e7a3376c2c` : sanitaires **6/6**, mobilité **9/9**, avec `LEGACY_BUILD64=true`. Ces tests prouvent les limites anciennes, pas une compatibilité transparente avec les nouvelles collections.
- Tests supplémentaires spécifiques : deux pièces au même niveau, pièce orpheline conservée, changement rapide de sélection, réouverture/reconnexion simulée, retrait exact d'une salle de bain, JSON malformé, ambiguïté de comptage, niveaux2/3, pages125/126 avec trous, plans historiques protégés, champs de mandat historiques et ID stable inter-appareils.
- QA PDF fictive : `/tmp/assist2-mandate-qa/`, les trois PDF de deux pages. QA canvas de géométrie : `/tmp/assist2-ui-qa/plans-fictionnels.png` ; les glyphes d'icônes du test Flutter ne remplacent pas une recette du bundle web final.

## Limites et suite d'intégration

- Aucun essai physique caméra/portrait, micro, Pencil ou migration des données d'un iPad. L'iPad Christelle est indisponible.
- Les essais hors ligne utilisent des dépôts fictifs ou SQLite de test selon la suite ; ils ne prouvent pas l'état de la file réelle d'un appareil.
- Les protections serveur `collections-v2`, CAS et import mandat doivent être intégrées par Main avant activation. Un build64 peut perdre les collections nouvelles sans ces protections ; un refus explicite doit préserver sa file.
- La génération du rapport complet, ses annexes, et les candidats web/TestFlight relèvent de la validation de Main. Les PDF inspectés ici sont les mandats fictifs, pas les rapports réels de Coralie ou Christelle.
- Les listes sanitaires anciennes ambiguës demandent vérification ; aucun réappariement silencieux n'a été introduit.
- Ne pas réactiver la suppression de plans par renumérotation pour contourner l'absence de tombstone.
