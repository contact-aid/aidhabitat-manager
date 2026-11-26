#!/usr/bin/env bash
# Diagnostic en lecture seule des enregistrements de visite (assistant IA).
# N'affiche aucun contenu clinique : propriétaire, dates, statut, nombre
# d'extraits reçus, durée audio, message d'erreur, échecs, notes appliquées.
#
# Depuis le Mac :
#   ssh root@157.180.20.97 'OWNER=christelle bash -s' < tools/diagnose-visit-recordings.sh
# OWNER filtre sur une partie de l'e-mail (facultatif), DAYS sur l'ancienneté (14 par défaut).

set -euo pipefail
API="$(docker ps --format '{{.Names}}' | grep -i 'aidhabitat-api' | head -1)"
[ -n "$API" ] || { echo "Conteneur API introuvable." >&2; exit 1; }

echo "== Configuration (sans secrets) =="
docker exec "$API" sh -c 'echo "VISIT_ASSISTANT_ENABLED=${VISIT_ASSISTANT_ENABLED:-<absent>}"; echo "AI_PROVIDER=${AI_PROVIDER:-<absent>}"; [ -n "${OPENAI_API_KEY:-}${OPENAI_API_KEY_FILE:-}" ] && echo "Clé OpenAI : configurée" || echo "Clé OpenAI : ABSENTE"'
docker inspect "$API" --format 'Image {{.Config.Image}} | démarré {{.State.StartedAt}}'

echo; echo "== Enregistrements des ${DAYS:-14} derniers jours =="
docker exec -e OWNER="${OWNER:-}" -e DAYS="${DAYS:-14}" "$API" node --input-type=module -e '
import fs from "node:fs/promises"; import path from "node:path";
const base = process.env.AIDHABITAT_DATA_DIR_PATH || "/app/server/data";
const root = path.join(base, "visit-assistant");
const since = Date.now() - Number(process.env.DAYS) * 86400e3;
const rows = [];
const owners = {};
const dirs = await fs.readdir(root).catch(e => { console.log("Dossier", root, ":", e.code); return []; });
console.log("Dossier de données :", root, "|", dirs.length, "dossier(s) patient");
for (const d of dirs) {
  for (const id of await fs.readdir(path.join(root, d)).catch(() => [])) {
    let job; try { job = JSON.parse(await fs.readFile(path.join(root, d, id, "job.json"), "utf8")); } catch { continue; }
    if (Date.parse(job.createdAt) < since) continue;
    owners[job.owner] = (owners[job.owner] ?? 0) + 1;
    if (process.env.OWNER && !String(job.owner).includes(process.env.OWNER.toLowerCase())) continue;
    const files = (await fs.readdir(path.join(root, d, id))).filter(f => f.endsWith(".m4a")).length;
    rows.push({ créé: job.createdAt, owner: job.owner, dossier: String(job.dossierId).slice(0, 8), statut: job.status,
      extraits: `${job.chunks?.length ?? 0}/${job.chunkCount ?? "?"} (${files} fichiers)`,
      audio_min: Math.round((job.chunks ?? []).reduce((s, c) => s + c.duration, 0) / 60),
      transcrits: job.transcript?.length ?? 0, échecs: job.processingFailures ?? 0,
      retryAfter: job.retryAfter ?? "", notes: job.notesAppliedAt ?? "",
      erreur: job.error ? String(job.error.message ?? job.error).slice(0, 200) : "",
      échec: job.failure ? `${job.failure.stage} | ${job.failure.code} | ${String(job.failure.reason).slice(0, 200)} | ${job.failure.at}` : "" });
  }
}
rows.sort((a, b) => a.créé.localeCompare(b.créé));
console.log("Tous propriétaires confondus :", JSON.stringify(owners));
console.log(rows.length ? JSON.stringify(rows, null, 1) : "Aucun enregistrement reçu par le serveur sur la période.");
'

echo; echo "== ffmpeg dans le conteneur =="
docker exec "$API" sh -c 'command -v ffmpeg >/dev/null && ffmpeg -version | head -1 || echo "ffmpeg ABSENT"'

echo; echo "== Suivi d'usage OpenAI (20 dernières lignes, sans contenu) =="
docker exec "$API" sh -c 'f="${AIDHABITAT_DATA_DIR_PATH:-/app/server/data}/visit-assistant-usage.jsonl"; [ -f "$f" ] && tail -20 "$f" || echo "Fichier absent : $f"'

echo; echo "== Journaux API [visit-assistant] (7 derniers jours) =="
docker logs --since 168h "$API" 2>&1 | grep -iE "visit-assistant|visit assistant|openai" | tail -40 || true
