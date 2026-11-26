#!/usr/bin/env bash
# Lance tools/create-sync-archive-table.mjs sur le serveur, dans un conteneur
# temporaire à l'image de l'API, avec ses accès NocoDB (jamais affichés).
#
# Depuis le Mac, à la racine du dépôt :
#   COPYFILE_DISABLE=1 tar -cf - tools/create-sync-archive-table.mjs server/syncArchive.mjs \
#     | ssh root@157.180.20.97 'rm -rf /root/aidhabitat-sync-archive && mkdir -p /root/aidhabitat-sync-archive && tar -C /root/aidhabitat-sync-archive -xf -'
#   ssh root@157.180.20.97 'bash -s' < tools/run-sync-archive-setup-on-server.sh            # lecture seule
#   ssh root@157.180.20.97 'APPLY=1 bash -s' < tools/run-sync-archive-setup-on-server.sh    # création

set -euo pipefail
DIR="${DIR:-/root/aidhabitat-sync-archive}"
API="$(docker ps --format '{{.Names}}' | grep -i 'aidhabitat-api' | head -1)"
[ -n "$API" ] || { echo "Conteneur API introuvable." >&2; exit 1; }
[ -f "$DIR/tools/create-sync-archive-table.mjs" ] && [ -f "$DIR/server/syncArchive.mjs" ] \
  || { echo "Fichiers absents dans $DIR : les envoyer d'abord depuis le Mac." >&2; exit 1; }

ENV_FILE="$(mktemp)"; chmod 600 "$ENV_FILE"; trap 'rm -f "$ENV_FILE"' EXIT
docker exec "$API" env | grep -E '^NOCODB_(API_URL|API_TOKEN|BASE_ID)=' > "$ENV_FILE"

ARGS=()
[ "${APPLY:-0}" = "1" ] && ARGS=(--apply)
docker run --rm --env-file "$ENV_FILE" \
  -v "$DIR/tools:/work/tools:ro" -v "$DIR/server:/work/server:ro" \
  --entrypoint node "$(docker inspect -f '{{.Config.Image}}' "$API")" \
  /work/tools/create-sync-archive-table.mjs "${ARGS[@]}"
