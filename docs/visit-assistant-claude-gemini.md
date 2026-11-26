# Assistant de visite : Claude pour l'écrit, Gemini pour l'audio

`AI_PROVIDER=anthropic` répartit les tâches entre deux fournisseurs :

| Tâche | Fournisseur | Modèle par défaut | Variable |
|---|---|---|---|
| Transcription audio (blocs de 90 s) | OpenRouter | `google/gemini-3.5-flash-lite` | `VISIT_TRANSCRIPTION_MODEL` |
| Lecture des manuscrits | API Claude | `claude-opus-5-5` (effort `low`) | `ANTHROPIC_VISIT_MODEL` |
| Faits sourcés, rédaction | API Claude | `claude-opus-5-5` (effort `high`) | `ANTHROPIC_VISIT_MODEL` |
| Questions, reformulation dans la visite | API Claude | `claude-opus-5-5` (effort `medium`) | `ANTHROPIC_VISIT_MODEL` |

L'API Claude n'accepte pas l'audio : la transcription reste chez un fournisseur
vocal. La reformulation des notes hors assistant de visite (`server/ai/rewrite.mjs`)
reste sur OpenRouter (DeepSeek V4 Flash), avec la même clé.

## Variables du service API (Easypanel)

```
AI_PROVIDER=anthropic
ANTHROPIC_API_KEY=<clé de la Console Claude>
OPENROUTER_API_KEY=<clé OpenRouter>
VISIT_ASSISTANT_ENABLED=true
```

Puis **Deploy** : une variable n'est appliquée qu'au redémarrage du conteneur.

## Comportement

- Claude Opus 5.5 réfléchit toujours ; l'effort par tâche règle la profondeur.
- Le repli serveur (`fallbacks: "default"`, bêta `server-side-fallback-2026-07-01`)
  relance automatiquement sur un autre modèle Claude si Opus refuse une requête.
  Un refus définitif est signalé comme échec, sources conservées.
- Les rubriques sont demandées en sortie JSON structurée. Les contraintes que
  l'API Claude ne prend pas en charge (bornes numériques, tailles de tableaux)
  sont retirées du schéma et restent vérifiées par le serveur.
- Crédits épuisés : `billing_error` côté Claude ou `insufficient_quota` côté
  OpenRouter affichent « Crédits du service IA épuisés » et suspendent la visite.
- OpenRouter impose toujours `zdr: true` et `data_collection: deny`, sans repli
  vers un autre fournisseur. Si aucun fournisseur Gemini ne respecte ces règles,
  la transcription échoue au lieu de s'en écarter.

## Ce qui n'existe qu'avec OpenAI

- Voix stables sur toute la visite (Gemini analyse chaque bloc à part).
- « Améliorer la transcription » d'une ancienne visite.
- Texte issu d'un moteur de transcription dédié : Gemini est un modèle généraliste.

## Coût estimé (prix OpenRouter et Claude du 26 novembre 2026)

- Audio Gemini 3.5 Flash-Lite : audio 0,30 $ et sortie 2,50 $ par million de
  tokens, soit environ 0,09 $ par heure de visite.
- Claude Opus 5.5 : 4 $ / 20 $ par million de tokens, soit environ 0,40 $ par
  visite (une quinzaine de pages manuscrites, faits et rédaction).

## Essai comparatif avant bascule

`tools/compare-visit-providers.sh` rejoue une visite déjà traitée par OpenAI dans
un conteneur temporaire de l'image candidate, données montées en lecture seule.
Il affiche l'écart de mots avec OpenAI, la part des nombres retrouvés et le coût,
et écrit le comparatif complet dans `/root/visit-compare` sur le serveur.
