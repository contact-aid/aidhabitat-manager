# Correction et reformulation IA accélérées

## Décision

Conserver une IA générative qui corrige les fautes et les tournures maladroites. Ajouter llama.cpp derrière l’API privée authentifiée Aid Habitat. Firefox privilégie cette API lorsque son statut annonce `ready: true` et `webEnabled: true`. L’activation est explicite, via `AI_REWRITE_WEB_ENABLED=true`. Les serveurs existants ne déclenchent donc pas automatiquement l’envoi des notes web.

Le contrôle de statut est partagé entre éditeurs, mémorisé trente secondes si prêt et cinq secondes sinon, avec une limite de 1,5 seconde et une clé par session et URL. Il ne contient aucune note. Une erreur de génération serveur reste visible dans la fenêtre, sans seconde génération automatique avec un autre moteur. Le modèle web demeure utilisable lorsque le mode serveur n’est pas disponible.

Le mode professionnel demande des corrections minimales et la reformulation des tournures incorrectes. Les protections existantes des noms et nombres sont conservées côté API. Une réponse tronquée est rejetée. Ces contrôles ne constituent pas une preuve de fidélité sémantique exhaustive ; la proposition reste à valider dans la fenêtre.

Ollama garde désormais le modèle dix minutes, au lieu de le décharger après chaque réponse. Cela améliore son parcours serveur à chaud, mais aucun gain Ollama n’a été mesuré dans cette session.

## Mesures réelles, notes fictives uniquement

Machine : Apple M4 Pro, 24 Go. llama.cpp b11574, accélération Metal, un slot, contexte 4096, température zéro, modèle déjà chargé. Les durées natives incluent le traitement complet et la réponse HTTP sur loopback, sans réseau de production ni attente concurrente. Chaque sortie est complète, pas seulement le premier token.

| Moteur | Note | Durée | Observation |
|---|---:|---:|---|
| Qwen3 0.6B WebLLM dans Firefox | 273 caractères | 10,657 s | Une information déformée ; écarté |
| Qwen3 1.7B Q4_K_M, llama.cpp | 273 / 803 caractères | 0,579 à 1,671 s | Accords et formulations incorrectes sur la note longue ; écarté |
| Qwen3 4B Q4_K_M, llama.cpp | 273 / 803 caractères | 1,323 à 3,484 s | Élision incorrecte sur la note longue ; écarté |
| Gemma 3 4B Q4_K_M, llama.cpp | 273 / 803 caractères | 1,671 à 4,007 s | Tournures incorrectes et changement d’une obligation en possibilité ; écarté |
| Qwen3 4B Instruct 2507 Q4_K_M, llama.cpp | 273 caractères, trois passages | 1,197 / 1,174 / 1,218 s | Mode professionnel final et validation des fragments protégés |
| Qwen3 4B Instruct 2507 Q4_K_M, llama.cpp | 803 caractères, trois passages | 3,663 / 3,934 / 3,563 s | Même configuration et validation |

Parcours Firefox réel avec le service Flutter et le dialogue, fixture de profil utilisant une session synthétique et une API locale de test : 3,973 secondes entre le clic et la proposition complète de la note de 803 caractères. Validation de la proposition effectuée. La fixture et son serveur ne sont pas livrés.

Ces deux notes et trois répétitions démontrent la faisabilité, pas un engagement de délai sur toutes les notes. Aucun benchmark du serveur de production, d’une file de requêtes ou des notes de 8000 caractères n’a été réalisé. Un VPS sans GPU ne peut pas être supposé aussi rapide que ce Mac. Avant activation générale, mesurer le moteur privé cible, le réseau et un corpus métier plus large. Les notes longues nécessiteront davantage de débit ou une autre stratégie mesurée.

## Configuration privée

Modèle conseillé pour les essais : [Qwen3 4B Instruct 2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507), variante sans raisonnement. Artefact GGUF testé : `unsloth/Qwen3-4B-Instruct-2507-GGUF`, révision `a06e946bb6b655725eafa393f4a9745d460374c9`, fichier `Qwen3-4B-Instruct-2507-Q4_K_M.gguf`.

Commande de test du moteur, sur la même machine que l’API :

```sh
llama-server -m /models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  --host 127.0.0.1 --port 8080 -c 8192 -ngl 99 -np 1 --log-disable
```

Le contexte 8192 de cette commande est destiné aux notes longues autorisées par l’API ; les mesures précédentes utilisaient 4096. Vérifier le placement effectif sur GPU au démarrage. Pour des conteneurs séparés, utiliser une adresse sur le réseau privé accessible à l’API. Ne pas publier directement le port du moteur.

Variables de l’API :

```dotenv
AI_REWRITE_PROVIDER=llama.cpp
LLAMA_REWRITE_BASE_URL=http://127.0.0.1:8080
LLAMA_REWRITE_MODEL=Qwen3-4B-Instruct-2507-Q4_K_M.gguf
AI_REWRITE_WEB_ENABLED=true
AI_REWRITE_TIMEOUT_MS=15000
```

Le timeout de quinze secondes permet d’afficher une erreur plutôt qu’une attente prolongée. Il ne transforme pas une génération lente en réponse de cinq secondes. L’API conserve ses contrôles d’authentification et sa limite de requêtes. Aucun prestataire d’inférence externe n’a été appelé pour ces essais.

Benchmark reproductible, exclusivement sur deux notes fictives intégrées au script :

```sh
AI_REWRITE_PROVIDER=llama.cpp \
LLAMA_REWRITE_BASE_URL=http://127.0.0.1:8080 \
node tools/benchmark-ai-rewrite.mjs
```

Le script affiche les sorties pour relecture et signale si les six générations sont sous cinq secondes. Il appelle directement le moteur via le module serveur, pas les routes d’authentification de production.

## Vérifications du code

- 446 tests serveur réussis, dont neuf tests du module IA.
- 17 tests Flutter du service et du dialogue réussis.
- Analyse Flutter ciblée sans anomalie.
- Build web de production complet réussi, avec les 36 tests du moteur navigateur.
- Parcours Firefox du service web vers llama.cpp testé avec une note fictive.

Le code est préparé dans la PR. Aucun moteur n’est installé durablement et aucune configuration de production n’est modifiée par ces changements.
