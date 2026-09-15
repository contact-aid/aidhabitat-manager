# Reformulation locale iPad / web

Date : 15 septembre 2026. Modifications locales, sans publication ni nouvelle archive iPad.

## Perimetre

- iPad : conserver le plugin Foundation Models existant. Disponibilite verifiee au demarrage de l'editeur et au retour dans l'application. Aucun repli HTTP sur iOS, meme si des identifiants serveur sont fournis au service.
- Web : WebLLM 0.2.85 dans un Worker, WebGPU avec shader-f16 et contexte securise. Le bouton reste masque sur les navigateurs incompatibles.
- Telechargement volontaire d'environ 1 Go ; reserve verifiee de 1,3 Go. Le navigateur peut refuser le stockage persistant ou purger des donnees : le fonctionnement offline depend de la conservation effective des caches.
- Les appareils iPad incompatibles ne recoivent pas de moteur alternatif.
- Le texte original reste en place jusqu'a l'acceptation de la proposition. Une modification de la note pendant le traitement invalide la proposition.

## Moteur web

Modele : Qwen3-1.7B-q4f16_1-MLC, revision
`80b3abcec6c3b3f5355dc0cc99cc4fb578f192bc`.
Poids : 968001536 octets, hors tokenizer, runtime et interface.
Runtime WASM versionne dans son nom, SHA-256 :
`8161aaa4b40bccf19fcedb2f2e8c221eb9efb72d2198681f1958c9c1e05a682f`.

- Generation sans raisonnement affiche, contexte borne a 4096 tokens.
- Cache IndexedDB : les ressources manquantes passent par le fetch controle, contrairement a Cache.add.
- Le fetch du Worker refuse toute requete pendant la reformulation, y compris le telechargement implicite d'un modele manquant.
- Pendant la preparation seulement : GET vers la revision epinglee du modele ou le runtime local ; credentials omis, aucun referrer.
- Aucun texte de note dans les erreurs remontees par le Worker de production. Conversation du modele effacee apres chaque generation, Worker libere apres inactivite.
- Les identifiants de protection doivent etre conserves exactement une fois. Une perte, duplication ou renumerotation est refusee par Dart, sans remplacement de la note.
- Aucune garantie automatique de fidelite semantique : la relecture humaine reste indispensable, notamment pour les negations et incertitudes.

## Reouverture offline

Un service worker distinct est installe seulement apres accord de telechargement.
Le build genere une liste de fichiers statiques avec SHA-256. Une installation incomplete ou melangeant deux builds est refusee ; l'ancien cache n'est pas supprime par cet echec.
Le worker ne gere ni les routes API, ni les uploads, ni les documents patients, ni les requetes avec parametres.
Les coffres, comptes et files de synchronisation restent geres par le code existant.
L'ancienne desinscription PWA preserve ce worker opt-in. L'interface reste network-first en ligne.

## Verification

- 829 tests Flutter passes dans un worktree de verification sans apostrophe dans le chemin.
- 8 tests cibles de reformulation passes apres le dernier renforcement des identifiants (dont le rejet d'un chiffre ajoute a un identifiant).
- Analyse ciblee Flutter : aucune anomalie.
- 20 tests existants de publication et provenance : passes.
- 14 tests Node locaux passes : autorisations de telechargement, cache statique, integrite, absence de transport pendant la generation, conservation des erreurs et requetes de disponibilite concurrentes. Ils sont executes par le script de build web.
- Un premier moteur Qwen2.5-1.5B a ete ecarte apres une faute introduite dans un texte correct.
- Qwen3 a ete charge et execute avec de vrais poids dans le navigateur sur des notes synthetiques. Les essais de fidelite ne sont pas une validation clinique.
- Corpus final de trois notes synthetiques : identifiants proteges conserves, negations conservees sur ces exemples ; 9, 6 et 4 secondes avec moteur charge sur ce Mac. Ces durees ne couvrent pas le telechargement ou le chargement a froid et ne constituent pas un engagement de performance.
- Le script complet de build web a produit les fichiers de l'application et un manifeste de 240 ressources statiques. Les avertissements du dry-run Flutter Wasm concernent des dependances existantes ; la compilation JavaScript a reussi.
- Qwen3 final : fermeture du navigateur de test, arret du serveur local, reouverture depuis le cache puis reformulation reussie. La generation utilise le cache IndexedDB et le fetch du modele reste interdit. Il s'agit d'un banc synthetique, pas du parcours authentifie complet.
- Reformulation egalement reussie avec la CSP du Worker extraite de nginx.conf ; les trois empreintes des scripts inline correspondent au HTML.

## Avant diffusion

- Tester le bouton, le refus et l'acceptation d'une proposition sur un iPad compatible reel, Apple Intelligence activee et modele francais disponible, puis en mode avion.
- Verifier l'archive finale et les navigateurs effectivement utilises par l'equipe, y compris le temps de chargement a froid et la memoire disponible.
- Tester le parcours web complet avec un compte synthetique, la reouverture offline et la conservation du coffre. Le banc navigateur local du moteur ne remplace pas ce parcours authentifie.
- Publier le web avec `tool/build_web.sh` afin d'inclure le runtime et le manifeste offline ; aucune publication effectuee dans ce travail.
- Ne jamais publier le diagnostic `build-browser-fixture.mjs` : il est reserve aux donnees synthetiques, hors `web/` et hors build de production.

## Sources

- [WebLLM](https://webllm.mlc.ai/docs/user/basic_usage.html)
- [Modele et licence Qwen3](https://huggingface.co/Qwen/Qwen3-1.7B)
- [Disponibilite Apple Intelligence](https://support.apple.com/fr-fr/121115)
- [Foundation Models](https://developer.apple.com/videos/play/wwdc2025/286/)
