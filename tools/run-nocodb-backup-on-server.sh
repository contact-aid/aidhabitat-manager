#!/usr/bin/env bash
# Sauvegarde de NocoDB sur le serveur Easypanel, vérification, puis mise à
# disposition pour le NAS. Lancée chaque nuit par cron (voir
# setup-nas-backup-on-server.sh), ou à la main.
#
# Envoi des outils à jour depuis le Mac, à la racine du dépôt (la copie du
# code présente sur le serveur est plus ancienne et ne sait pas écrire une
# grosse base) :
#   COPYFILE_DISABLE=1 tar -C tools -cf - backup-nocodb.mjs nocodbBackupLib.mjs \
#       verify-nocodb-backup-stream.mjs run-nocodb-backup-on-server.sh \
#     | ssh root@157.180.20.97 'rm -rf /root/aidhabitat-tools && mkdir -p /root/aidhabitat-tools && tar -C /root/aidhabitat-tools -xf -'
# Lancement manuel :
#   ssh root@157.180.20.97 'bash /root/aidhabitat-tools/run-nocodb-backup-on-server.sh'
#
# Lecture seule pour NocoDB et pour l'API. Le fichier est d'abord écrit dans
# un dossier privé (STAGING_DIR), vérifié, puis seulement déplacé dans
# PUBLISH_DIR, où le NAS vient le chercher. Un fichier en cours d'écriture
# ou non vérifié n'est donc jamais visible par le NAS. Seules les KEEP
# dernières sauvegardes vérifiées restent sur le serveur (1,3 Go chacune).

set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-/root/aidhabitat-tools}"
STAGING_DIR="${STAGING_DIR:-/root/backups-nocodb}"
PUBLISH_DIR="${PUBLISH_DIR:-/srv/nocodb-backups}"
PUBLISH_GROUP="${PUBLISH_GROUP:-nasbackup}"
KEEP="${KEEP:-2}"

# Une seule sauvegarde à la fois (cron et lancement manuel).
exec 9>/run/aidhabitat-nocodb-backup.lock
flock -n 9 || { echo "Une sauvegarde est déjà en cours." >&2; exit 1; }

echo "== Sauvegarde NocoDB du $(date '+%d/%m/%Y %H:%M:%S') =="
API="$(docker ps --format '{{.Names}}' | grep -i 'aidhabitat-api' | head -1)"
[ -n "$API" ] || { echo "Conteneur API introuvable." >&2; exit 1; }
for f in backup-nocodb.mjs nocodbBackupLib.mjs verify-nocodb-backup-stream.mjs; do
  [ -f "$TOOLS_DIR/$f" ] || { echo "Outil absent : $TOOLS_DIR/$f (envoyer d'abord les outils depuis le Mac)" >&2; exit 1; }
done

echo "== Espace disque avant sauvegarde =="
df -h / | tail -1
FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
if [ "$FREE_KB" -lt 3000000 ]; then
  echo "Moins de 3 Go libres : sauvegarde annulée pour ne pas remplir le disque." >&2
  exit 1
fi

echo "== Mémoire disponible =="
free -m | awk 'NR<=2'
AVAIL_MB="$(free -m | awk '/^Mem:/ {print $7}')"
if [ "$AVAIL_MB" -lt 3500 ]; then
  echo "Moins de 3,5 Go de mémoire disponible : sauvegarde annulée pour ne pas gêner les autres services." >&2
  exit 1
fi

IMAGE="$(docker inspect -f '{{.Config.Image}}' "$API")"
mkdir -p "$STAGING_DIR"
chmod 700 "$STAGING_DIR"

ENV_FILE="$(mktemp)"
chmod 600 "$ENV_FILE"
trap 'rm -f "$ENV_FILE"' EXIT
docker exec "$API" env | grep -E '^NOCODB_(API_URL|API_TOKEN|BASE_ID)=' > "$ENV_FILE"
for name in NOCODB_API_URL NOCODB_API_TOKEN NOCODB_BASE_ID; do
  grep -q "^$name=" "$ENV_FILE" || { echo "Variable $name absente du conteneur API." >&2; exit 1; }
done

# Adresse NocoDB publique (https) : le réseau par défaut suffit. Adresse
# interne : le conteneur temporaire rejoint le réseau de l'API.
NETWORK_ARGS=()
if ! grep -q '^NOCODB_API_URL=https://' "$ENV_FILE"; then
  NETWORK="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$API" | awk '{print $1}')"
  NETWORK_ARGS=(--network "$NETWORK")
fi

echo "== Sauvegarde (image $IMAGE) =="
# RETENTION_DAYS très long : le tri des anciennes sauvegardes se fait plus
# bas, seulement après vérification de la nouvelle.
docker run --rm \
  "${NETWORK_ARGS[@]}" \
  --env-file "$ENV_FILE" \
  -e BACKUP_DIR=/backups \
  -e RETENTION_DAYS=3650 \
  -e PAGE_SIZE=25 \
  -e NODE_OPTIONS=--max-old-space-size=3072 \
  --memory 3500m \
  -v "$TOOLS_DIR:/tools:ro" \
  -v "$STAGING_DIR:/backups" \
  --entrypoint node \
  "$IMAGE" /tools/backup-nocodb.mjs

LATEST="$(ls -t "$STAGING_DIR"/aidhabitat-*.json.gz | head -1)"
NAME="$(basename "$LATEST")"
echo "== Vérification de $NAME =="
if ! docker run --rm \
  -e NODE_OPTIONS=--max-old-space-size=3072 \
  --memory 3500m \
  -v "$TOOLS_DIR:/tools:ro" \
  -v "$STAGING_DIR:/backups:ro" \
  --entrypoint node \
  "$IMAGE" /tools/verify-nocodb-backup-stream.mjs "/backups/$NAME"; then
  # Gardée pour diagnostic, jamais publiée. Seul le dernier échec est
  # conservé pour ne pas remplir le disque.
  mv "$LATEST" "$LATEST.failed"
  ls -1t "$STAGING_DIR"/*.failed | tail -n +2 | xargs -r rm -f
  echo "SAUVEGARDE EN ÉCHEC : vérification refusée, fichier gardé en $LATEST.failed" >&2
  exit 1
fi

# Vérifiée : mise à disposition du NAS. Le déplacement sur le même disque
# est instantané, le NAS ne voit jamais de fichier à moitié copié.
mkdir -p "$PUBLISH_DIR"
if getent group "$PUBLISH_GROUP" >/dev/null; then
  chown root:"$PUBLISH_GROUP" "$PUBLISH_DIR" "$LATEST"
  chmod 750 "$PUBLISH_DIR"
  chmod 640 "$LATEST"
else
  chmod 700 "$PUBLISH_DIR"
  chmod 600 "$LATEST"
fi
mv "$LATEST" "$PUBLISH_DIR/$NAME"

# Garde les KEEP dernières sauvegardes vérifiées, supprime les plus anciennes.
ls -1t "$PUBLISH_DIR"/aidhabitat-*.json.gz | tail -n +"$((KEEP + 1))" | while read -r old; do
  echo "Suppression de l'ancienne sauvegarde du serveur : $(basename "$old")"
  rm -f "$old"
done

echo "== Résultat =="
ls -lh "$PUBLISH_DIR"
df -h / | tail -1
echo "SAUVEGARDE OK : $NAME"
