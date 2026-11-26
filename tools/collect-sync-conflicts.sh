#!/usr/bin/env bash
# Relevé des conflits de synchronisation enregistrés par l'API (lecture seule).
#
# À lancer SUR le serveur Easypanel (root), par exemple :
#   ssh root@157.180.20.97 'bash -s' < tools/collect-sync-conflicts.sh
#
# Ce script ne modifie ni l'API, ni NocoDB, ni aucun conteneur.
# Il lit les journaux Docker du conteneur API, extrait les blocs
# `[sync-conflict]` (code, noms de champs, writeId : aucune donnée patient)
# et les ajoute, sans doublon, à un fichier d'historique. Les journaux Docker
# tournent (3 fichiers de 10 Mo) : relancer le script tous les 2 ou 3 jours
# pendant deux semaines pour ne rien perdre.

set -euo pipefail

HISTORY="${HISTORY:-/var/log/aidhabitat-sync-conflicts.log}"
CONTAINER="${CONTAINER:-$(docker ps --format '{{.Names}}' | grep -i 'aidhabitat-api' | head -1)}"

if [ -z "$CONTAINER" ]; then
  echo "Conteneur API introuvable. Noms disponibles :" >&2
  docker ps --format '{{.Names}}' >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Un bloc console.warn peut tenir sur plusieurs lignes : on le recolle en une
# seule ligne, préfixée par l'horodatage Docker de sa première ligne.
docker logs --timestamps "$CONTAINER" 2>&1 | awk '
  /\[sync-conflict\]/ { block = $0; open = 1; if ($0 ~ /\}[[:space:]]*$/) { print block; open = 0 }; next }
  open { sub(/^[^ ]+ /, ""); block = block " " $0; if ($0 ~ /\}[[:space:]]*$/) { print block; open = 0 } }
' > "$TMP"

touch "$HISTORY"
cat "$HISTORY" "$TMP" | sort -u > "$HISTORY.new" && mv "$HISTORY.new" "$HISTORY"

echo "Conteneur : $CONTAINER"
echo "Fichier d'historique : $HISTORY"
echo "Période couverte : $(head -1 "$HISTORY" | cut -c1-19) → $(tail -1 "$HISTORY" | cut -c1-19)"
echo "Total des conflits : $(wc -l < "$HISTORY")"
echo
echo "== Par type de conflit =="
grep -o "code: '[A-Z_]*'" "$HISTORY" | sort | uniq -c | sort -rn || true
echo
echo "== Par champ en conflit =="
sed -n "s/.*conflictFields: \[\([^]]*\)\].*/\1/p" "$HISTORY" | tr ',' '\n' \
  | tr -d " '" | grep -v '^$' | sort | uniq -c | sort -rn || true
echo
echo "== Par champ « annulé localement » (retainedFields) =="
sed -n "s/.*retainedFields: \[\([^]]*\)\].*/\1/p" "$HISTORY" | tr ',' '\n' \
  | tr -d " '" | grep -v '^$' | sort | uniq -c | sort -rn || true
echo
echo "== Autres refus visibles dans les journaux actuels (notes, contexte, anciens builds) =="
docker logs "$CONTAINER" 2>&1 | grep -o -E 'NOTE_PAGE_[A-Z_]*CONFLICT|NOTE_PAGE_DUPLICATES_REQUIRE_REVIEW|CONTEXT_[A-Z_]*(CONFLICT|REVIEW|MIGRATION|CHANGED)|SYNC_BASELINE_REQUIRED|SYNC_MUTATION_ID_REQUIRED' \
  | sort | uniq -c | sort -rn || true
