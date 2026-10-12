# Attente et latence de reformulation

## Comportement

La fenêtre de vérification s’ouvre avant la vérification du cache, l’installation éventuelle et la génération. La note originale reste lisible pendant que la proposition affiche une animation et la phase du moteur. La proposition devient modifiable après une réponse complète et validée par le service. Une erreur est affichée dans la fenêtre avec un bouton Réessayer. Fermer ou conserver l’original annule le worker web et ignore tout résultat tardif. Les vérifications de changement de la note sont conservées avant affichage et avant application.

Le contrôle de disponibilité des éditeurs partage désormais une seule requête en cours. Dès qu’un modèle explicitement installé est détecté, le bridge demande son chargement en arrière-plan depuis IndexedDB. La reformulation attend ce même chargement au lieu de créer un second moteur ou d’obtenir une erreur de concurrence. Le worker déjà chargé évite les nouvelles recherches de ressources dans le cache. Le chargement interdit les téléchargements ; aucun texte de note ne lui est fourni. Le délai de libération après dix minutes d’inactivité reste en place.

## Objectif de cinq secondes

Ces changements déplacent le chargement à froid avant le clic lorsque le navigateur a le temps de le terminer. Ils ne garantissent pas une reformulation complète en cinq secondes. Le nombre de tokens à produire, le GPU et le navigateur déterminent aussi le temps de décodage.

Les mesures consignées lors du correctif Firefox précédent étaient de 50,3 puis 8,9 secondes pour une entrée répétitive de 2 088 caractères avec sortie de 173 caractères, et 24,7 puis 24,9 secondes pour une entrée variée de 773 caractères avec sortie de 765 caractères. Ce sont des mesures antérieures, pas une comparaison avant/après de cette PR. Le parcours à neuf buffers utilise des passages bornés et séquentiels ; il reste inchangé pour préserver sa compatibilité.

Pour valider cinq secondes, il faudra mesurer le moteur réel sur un corpus représentatif dans le Firefox utilisé. Un modèle plus petit nécessiterait de nouveaux essais de fidélité en français ; un serveur d’inférence accéléré modifierait le lieu de traitement des notes. Aucune de ces deux modifications n’est activée ici.

## Vérification

- 36 tests Node du moteur local, du bridge, du cache et de l’installation.
- 14 tests Flutter du dialogue et du service de reformulation : affichage pendant une réponse différée, validation désactivée, édition, annulation, résultat tardif, erreur et nouvelle tentative.
- Analyse Flutter ciblée sans anomalie.
- Build web de production complet via tool/build_web.sh, manifeste hors ligne généré ; 20 contrôles de flux critiques réussis.
- Firefox, fixture synthétique utilisant le composant réel avec une réponse différée de quinze secondes : affichage d’attente, transition vers le texte modifiable, modification manuelle et fermeture après validation. La durée de cette fixture est artificielle et ne mesure pas l’inférence.
- Captures locales dans output/playwright, hors des fichiers de publication.
