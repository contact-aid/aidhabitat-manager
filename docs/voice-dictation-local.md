# Dictée vocale locale

La web app utilise Whisper base multilingue dans un worker WASM, sur Firefox,
Chrome et Safari, y compris le navigateur iPad. Le premier usage télécharge
le modèle (environ 80 Mo), puis les fichiers sont conservés dans le cache du
navigateur. L’audio et le texte ne sont pas envoyés à un serveur de transcription.
La langue est fixée au français. Le runtime est hébergé avec l’application,
le modèle est téléchargé depuis une révision fixe de Hugging Face.

## Utilisation

1. Toucher le micro et autoriser son accès.
2. Au premier usage, attendre la fin de la préparation. L’icône Arrêter indique
   que l’enregistrement a commencé.
3. Dicter, puis toucher Arrêter. Chaque enregistrement est limité à une minute.
4. Attendre la transcription locale. Le texte remplace la sélection courante,
   en conservant le reste de la note. Toucher le bouton pendant la transcription
   permet de l’annuler.

La transcription n’est pas affichée en direct. Sa durée dépend de l’appareil.
Une erreur conserve le texte existant. Une annulation ou la fermeture de
l’éditeur empêche tout résultat tardif d’être inséré dans un autre champ.
La dictée ne prépare pas l’ouverture hors ligne de toute l’application.

L’application iPad native conserve la reconnaissance française sur l’appareil
via Apple. Les callbacks restent attachés jusqu’au résultat final, y compris
quand l’arrêt du microphone arrive avant celui-ci. Le français hors ligne doit
être disponible dans les réglages de l’appareil.

## Construction et vérification

`aid_habitat_app/tool/build_web.sh` installe les dépendances verrouillées de
`tool/local_voice`, produit le worker et copie le runtime ONNX dans
`web/local-voice`. Les fichiers générés sont exclus de Git. Nginx sert les
modules `.mjs` en JavaScript et refuse un fichier de runtime absent avec 404.

Vérifications automatisées :

- `node --test tools/test-voice-*.mjs` : formats WebM/MP4/Ogg, rééchantillonnage
  mono à 16 kHz, autorisation refusée, annulation, silence, arrêt automatique,
  callbacks web et absence d’insertion tardive.
- `bash aid_habitat_app/tool/test_safely.sh test/components/voice_dictation_button_test.dart` :
  insertion au curseur, sélection, conservation du texte et résultat final iPad.
- Compilation Flutter web en mode release et analyse Dart ciblée.

Un échantillon audio français synthétique a été transcrit avec le vrai modèle
sur Chrome, Firefox et WebKit de bureau. Cela valide le moteur et les formats,
mais ne remplace pas le test avec un microphone physique sur iPad.

Avant la mise en production, vérifier sur iPad : la demande d’autorisation,
le téléchargement initial, une dictée puis un arrêt manuel, l’annulation,
et la réception du texte final dans l’application native.
