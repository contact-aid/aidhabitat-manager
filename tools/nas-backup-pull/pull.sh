#!/bin/sh
# Récupère chaque nuit, depuis le NAS, les sauvegardes NocoDB vérifiées du
# serveur, et garde un historique long sur le NAS.
#
# Tourne dans un conteneur Alpine (voir compose.yaml). C'est le NAS qui se
# connecte au serveur, en lecture seule : le serveur n'a aucun accès au NAS.
#
# Variables :
#   SERVER          adresse du serveur (157.180.20.97)
#   REMOTE_USER     compte de lecture sur le serveur (nasbackup)
#   PULL_TIME       heure de récupération HH:MM, fuseau TZ (05:00)
#   KEEP_DAILY      nombre de sauvegardes récentes gardées (30)
#   KEEP_MONTHLY    nombre de sauvegardes du 1er du mois gardées en plus (12)
#   RUN_AT_START    1 = récupération immédiate au démarrage (pour tester)

set -eu

SERVER="${SERVER:?SERVER requis}"
REMOTE_USER="${REMOTE_USER:-nasbackup}"
PULL_TIME="${PULL_TIME:-05:00}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEY="${KEY:-/keys/id_ed25519}"
DEST="${DEST:-/backups}"

log() { echo "[$(date '+%d/%m/%Y %H:%M:%S')] $*"; }

# Conteneur Alpine : installe les outils. NAS sans Docker : déjà présents.
if ! command -v rsync >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1; then
  apk add --no-cache rsync openssh-client tzdata >/dev/null
fi

mkdir -p "$(dirname "$KEY")" "$DEST"
chmod 700 "$(dirname "$KEY")" "$DEST"
if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C 'aidhabitat-nas' -f "$KEY"
  log "Nouvelle clé créée."
fi
log "Clé publique du NAS, à installer sur le serveur :"
cat "$KEY.pub"

pull() {
  log "Récupération depuis $REMOTE_USER@$SERVER"
  # --ignore-existing : une sauvegarde déjà sur le NAS n'est jamais réécrite.
  # Sans --delete : une suppression sur le serveur ne touche pas le NAS.
  if rsync -a --ignore-existing --partial-dir=.partial --chmod=F600,D700 \
      -e "ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(dirname "$KEY")/known_hosts" \
      "$REMOTE_USER@$SERVER:/" "$DEST/"; then
    log "Récupération réussie."
  else
    log "ÉCHEC de la récupération (les sauvegardes déjà sur le NAS sont intactes)."
    return 1
  fi

  # Historique : les KEEP_DAILY plus récentes + les KEEP_MONTHLY plus récentes
  # du 1er du mois. Les noms commencent par la date, le tri alphabétique est
  # donc chronologique.
  keep="$( { ls -1 "$DEST"/aidhabitat-*.json.gz 2>/dev/null | sort -r | head -n "$KEEP_DAILY";
             ls -1 "$DEST"/aidhabitat-*-01_*.json.gz 2>/dev/null | sort -r | head -n "$KEEP_MONTHLY"; } | sort -u)"
  total="$(ls -1 "$DEST"/aidhabitat-*.json.gz 2>/dev/null | wc -l)"
  # Ne supprime rien tant qu'il y a moins de KEEP_DAILY sauvegardes.
  if [ "$total" -gt "$KEEP_DAILY" ]; then
    for f in "$DEST"/aidhabitat-*.json.gz; do
      echo "$keep" | grep -qxF "$f" || { log "Suppression de l'ancienne : $(basename "$f")"; rm -f "$f"; }
    done
  fi
  log "Sauvegardes présentes sur le NAS : $(ls -1 "$DEST"/aidhabitat-*.json.gz 2>/dev/null | wc -l)"
  log "Dernière : $(ls -1 "$DEST"/aidhabitat-*.json.gz 2>/dev/null | sort | tail -1 | xargs -r basename)"
}

# NAS sans Docker : lancé par cron, une récupération puis fin.
if [ "${RUN_ONCE:-0}" = "1" ]; then
  pull
  exit $?
fi

[ "${RUN_AT_START:-0}" = "1" ] && { pull || true; }

# Secondes à attendre jusqu'à PULL_TIME (aujourd'hui ou demain).
seconds_until() {
  target_h="$(echo "${1%%:*}" | sed 's/^0//')"
  target_m="$(echo "${1##*:}" | sed 's/^0//')"
  now_h="$(date +%H | sed 's/^0//')"
  now_m="$(date +%M | sed 's/^0//')"
  now_s="$(date +%S | sed 's/^0//')"
  wait=$(( (${target_h:-0} * 3600 + ${target_m:-0} * 60) - (${now_h:-0} * 3600 + ${now_m:-0} * 60 + ${now_s:-0}) ))
  [ "$wait" -le 0 ] && wait=$((wait + 86400))
  echo "$wait"
}

while true; do
  wait="$(seconds_until "$PULL_TIME")"
  log "Prochaine récupération à $PULL_TIME (dans $((wait / 60)) min)"
  sleep "$wait"
  pull || true
done
