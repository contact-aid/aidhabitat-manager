#!/usr/bin/env bash
# Installation unique, sur le serveur Easypanel, de :
#   1. la sauvegarde NocoDB quotidienne (cron à 2 h 30, heure du serveur) ;
#   2. un compte « nasbackup » qui ne peut QUE lire les sauvegardes vérifiées,
#      avec la clé SSH du NAS (pas de mot de passe, pas de shell, pas de
#      redirection de port, lecture seule du dossier /srv/nocodb-backups).
#
# Le script peut être relancé sans risque : il ne supprime aucune sauvegarde.
#
# Prérequis : outils envoyés dans /root/aidhabitat-tools (voir
# run-nocodb-backup-on-server.sh) et clé publique du NAS (affichée par le
# conteneur du NAS au premier démarrage). Depuis le Mac :
#   ssh root@157.180.20.97 "NAS_PUBLIC_KEY='ssh-ed25519 AAAA... aidhabitat-nas' bash -s" \
#     < tools/setup-nas-backup-on-server.sh

set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-/root/aidhabitat-tools}"
STAGING_DIR="${STAGING_DIR:-/root/backups-nocodb}"
PUBLISH_DIR="${PUBLISH_DIR:-/srv/nocodb-backups}"
USER_NAME="nasbackup"
CRON_FILE="/etc/cron.d/aidhabitat-nocodb-backup"
LOG_FILE="/var/log/aidhabitat-nocodb-backup.log"

[ -f "$TOOLS_DIR/run-nocodb-backup-on-server.sh" ] || {
  echo "Outils absents dans $TOOLS_DIR : les envoyer d'abord depuis le Mac." >&2; exit 1; }

case "${NAS_PUBLIC_KEY:-}" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) ;;
  *) echo "NAS_PUBLIC_KEY manquante ou invalide (doit commencer par ssh-ed25519)." >&2; exit 1 ;;
esac
case "$NAS_PUBLIC_KEY" in
  *$'\n'*|*\"*) echo "NAS_PUBLIC_KEY ne doit contenir qu'une seule ligne, sans guillemets." >&2; exit 1 ;;
esac

RRSYNC="$(command -v rrsync || true)"
[ -n "$RRSYNC" ] || { echo "rrsync introuvable : installer le paquet rsync (apt install rsync)." >&2; exit 1; }

echo "== Compte $USER_NAME =="
if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "/home/$USER_NAME" --shell /bin/sh "$USER_NAME"
fi
passwd -l "$USER_NAME" >/dev/null
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.ssh"
# restrict : ni terminal, ni redirection de port, ni agent.
# rrsync -ro : seule une lecture rsync du dossier publié est autorisée.
printf 'restrict,command="%s -ro %s" %s\n' "$RRSYNC" "$PUBLISH_DIR" "$NAS_PUBLIC_KEY" \
  > "/home/$USER_NAME/.ssh/authorized_keys"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh/authorized_keys"
chmod 600 "/home/$USER_NAME/.ssh/authorized_keys"

echo "== Dossier publié $PUBLISH_DIR =="
install -d -m 750 -o root -g "$USER_NAME" "$PUBLISH_DIR"
# Reprend les sauvegardes manuelles déjà vérifiées (celle du 26/11 incluse).
# Les fichiers marqués .failed restent dans le dossier privé.
for f in "$STAGING_DIR"/aidhabitat-*.json.gz; do
  [ -e "$f" ] || continue
  chown root:"$USER_NAME" "$f"
  chmod 640 "$f"
  mv -n "$f" "$PUBLISH_DIR/"
  echo "Publiée : $(basename "$f")"
done
for f in "$PUBLISH_DIR"/aidhabitat-*.json.gz; do
  [ -e "$f" ] || continue
  chown root:"$USER_NAME" "$f"
  chmod 640 "$f"
done

echo "== Sauvegarde quotidienne =="
cat > "$CRON_FILE" <<EOF
# Sauvegarde NocoDB aid'habitat, vérifiée puis publiée pour le NAS.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 2 * * * root bash $TOOLS_DIR/run-nocodb-backup-on-server.sh >> $LOG_FILE 2>&1
EOF
chmod 644 "$CRON_FILE"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

cat > /etc/logrotate.d/aidhabitat-nocodb-backup <<EOF
$LOG_FILE {
  weekly
  rotate 8
  compress
  missingok
  notifempty
}
EOF

echo "== Résultat =="
echo "Fuseau du serveur : $(date +%Z) (la sauvegarde part à 2 h 30 dans ce fuseau)"
ls -l "$PUBLISH_DIR"
echo "Clé du NAS installée pour $USER_NAME, accès en lecture seule à $PUBLISH_DIR."
echo "INSTALLATION OK"
