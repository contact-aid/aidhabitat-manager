#!/usr/bin/env bash
# Test de l'appel de transcription française OpenAI depuis le conteneur API.
# Envoie 2 secondes de son synthétique (aucune donnée patient) avec les mêmes
# paramètres que server/openaiFrenchTranscript.mjs et affiche le code HTTP et
# le message d'erreur OpenAI. N'affiche jamais la clé. Coût : quasi nul.
#
# Depuis le Mac :
#   ssh root@157.180.20.97 'bash -s' < tools/probe-openai-transcription.sh

set -euo pipefail
SERVICE="${SERVICE:-aidhabitat-api-staging}"  # service Easypanel de production, malgré son nom
API="$(docker ps --format '{{.Names}}' | grep -E "^apps_${SERVICE}\.[0-9]+\." | head -1)"
[ -n "$API" ] || { echo "Conteneur API introuvable." >&2; exit 1; }

docker exec "$API" sh -c 'ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=2" -c:a aac /tmp/probe.m4a'
docker exec "$API" node --input-type=module -e '
import fs from "node:fs/promises";
const key = (process.env.OPENAI_API_KEY || (process.env.OPENAI_API_KEY_FILE ? (await fs.readFile(process.env.OPENAI_API_KEY_FILE, "utf8")) : "")).trim();
if (!key) { console.log("Clé OpenAI introuvable dans le conteneur."); process.exit(1); }
const auth = { Authorization: `Bearer ${key}` };
const model = process.env.OPENAI_VISIT_TEXT_TRANSCRIPTION_MODEL || "gpt-transcribe";
const show = async (label, r) => { const body = await r.text(); console.log(`${label} -> HTTP ${r.status}`); console.log(body.slice(0, 800)); };
await show(`GET /v1/models/${model}`, await fetch(`https://api.openai.com/v1/models/${model}`, { headers: auth }));
for (const m of [model, "gpt-4o-transcribe-diarize"]) {
  const form = new FormData();
  form.append("file", new Blob([await fs.readFile("/tmp/probe.m4a")], { type: "audio/mp4" }), "visit.m4a");
  form.append("model", m);
  if (m === model) form.append("languages[]", "fr");
  if (m !== model) form.append("response_format", "diarized_json");
  await show(`POST /v1/audio/transcriptions (${m})`, await fetch("https://api.openai.com/v1/audio/transcriptions", { method: "POST", headers: auth, body: form }));
}
'
docker exec "$API" rm -f /tmp/probe.m4a
