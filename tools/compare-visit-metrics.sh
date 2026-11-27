#!/usr/bin/env bash
# Lecture seule : chiffres par bloc du dernier comparatif (aucun mot affiché).
#   ssh root@157.180.20.97 'bash -s' < tools/compare-visit-metrics.sh
set -euo pipefail
F="$(ls -t /root/visit-compare/*.json | head -1)"
IMAGE="$(docker ps --format '{{.Image}} {{.Names}}' | grep -E ' apps_aidhabitat-api-staging\.[0-9]+\.' | cut -d' ' -f1)"
echo "Fichier : $F"
docker run --rm -i -v "$F":/in.json:ro "$IMAGE" node --input-type=module - <<'JS'
import fs from 'node:fs';
const { audio } = JSON.parse(fs.readFileSync('/in.json', 'utf8'));
const words = t => String(t ?? '').toLowerCase().split(/\s+/).filter(Boolean);
console.log('bloc | mots OpenAI | mots Gemini | écart | répétition Gemini (trigrammes en double)');
for (const a of audio) {
  const g = words(a.gemini), o = words(a.openai);
  const tri = g.slice(2).map((_, i) => g.slice(i, i + 3).join(' '));
  const rep = tri.length ? 1 - new Set(tri).size / tri.length : 0;
  console.log(`${a.index} | ${o.length} | ${a.error ? 'échec' : g.length} | ${a.error ? '-' : (a.wer * 100).toFixed(0) + ' %'} | ${a.error ? '-' : (rep * 100).toFixed(0) + ' %'}`);
}
JS
