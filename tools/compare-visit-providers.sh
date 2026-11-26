#!/usr/bin/env bash
# Essai comparatif, sans effet sur la production : rejoue une visite déjà
# traitée par OpenAI avec Gemini (audio, via OpenRouter) et Claude Opus
# (manuscrits, faits, rédaction).
#
# - Lance un conteneur TEMPORAIRE de l'image candidate ; le service API live
#   n'est ni arrêté ni modifié.
# - Les données de visite sont montées en LECTURE SEULE : aucun job, aucune
#   note, aucun fichier d'usage n'est écrit.
# - Le comparatif complet (contenu clinique) est écrit sur le serveur dans
#   /root/visit-compare (0600). Le terminal n'affiche que des mesures.
# - Coût : quelques dizaines de centimes (crédits OpenRouter + Claude).
#
# Prérequis : ANTHROPIC_API_KEY et OPENROUTER_API_KEY présentes dans les
# variables du service API (AI_PROVIDER peut rester à openai).
#
# Depuis le Mac :
#   ssh root@157.180.20.97 'IMAGE=ghcr.io/contact-aid/aidhabitat-api:<tag> bash -s' < tools/compare-visit-providers.sh
# Options : RECORDING=<id 32 hex> (défaut : dernière visite complète),
#           CHUNKS=10 (blocs audio de ~90 s comparés), PAGES=3 (pages manuscrites relues).

set -euo pipefail
IMAGE="${IMAGE:?IMAGE requis (image candidate de l'API)}"
API="$(docker ps --format '{{.Names}}' | grep -i 'aidhabitat-api' | head -1)"
[ -n "$API" ] || { echo "Conteneur API introuvable." >&2; exit 1; }
DATA_SRC="$(docker inspect "$API" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')"
[ -n "$DATA_SRC" ] || { echo "Volume /data du conteneur API introuvable." >&2; exit 1; }

ENVF="$(mktemp)"; chmod 600 "$ENVF"; trap 'rm -f "$ENVF"' EXIT
docker inspect "$API" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -v '^$' > "$ENVF"
grep -q '^ANTHROPIC_API_KEY=.' "$ENVF" || { echo "ANTHROPIC_API_KEY absente du service API." >&2; exit 1; }
grep -q '^OPENROUTER_API_KEY=.' "$ENVF" || { echo "OPENROUTER_API_KEY absente du service API." >&2; exit 1; }

OUT=/root/visit-compare; mkdir -p "$OUT"; chmod 700 "$OUT"
docker pull -q "$IMAGE" >/dev/null
docker run --rm -i --env-file "$ENVF" -e AI_PROVIDER=anthropic \
  -e RECORDING="${RECORDING:-}" -e CHUNKS="${CHUNKS:-10}" -e PAGES="${PAGES:-3}" \
  -v "$DATA_SRC":/data:ro -v "$OUT":/out "$IMAGE" node --input-type=module - <<'JS'
import fs from 'node:fs/promises';
import path from 'node:path';
const { createVisitProvider } = await import('/app/server/visitAssistant.mjs');
const root = path.join(process.env.AIDHABITAT_DATA_DIR_PATH || '/app/server/data', 'visit-assistant');

let found = null;
for (const d of await fs.readdir(root)) for (const id of await fs.readdir(path.join(root, d)).catch(() => [])) {
  let job; try { job = JSON.parse(await fs.readFile(path.join(root, d, id, 'job.json'), 'utf8')); } catch { continue; }
  if (process.env.RECORDING ? id !== process.env.RECORDING : job.status !== 'complete') continue;
  if (!found || job.createdAt > found.job.createdAt) found = { job, dir: path.join(root, d, id) };
}
if (!found) { console.log('Aucune visite complète trouvée.'); process.exit(1); }
const { job, dir } = found;
console.log(`Visite ${job.id} du ${job.createdAt.slice(0, 10)} : ${job.chunks.length} blocs, ${job.context.handwritten?.length ?? 0} pages manuscrites.`);

const usage = [];
const provider = createVisitProvider({ env: process.env, onUsage: entry => usage.push(entry) });
const words = t => String(t).toLowerCase().normalize('NFC').replace(/[^\p{L}\p{N}' ]+/gu, ' ').split(/\s+/).filter(Boolean);
function wer(ref, hyp) {
  const a = words(ref), b = words(hyp); if (!a.length) return b.length ? 1 : 0;
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[b.length] / a.length;
}
const numbers = t => String(t).match(/\d+(?:[.,]\d+)?/g) ?? [];
const kept = (ref, hyp) => { const r = numbers(ref); if (!r.length) return null; const h = numbers(hyp); return r.filter(n => h.includes(n)).length / r.length; };
const fail = e => `ÉCHEC (${e.statusCode ?? '?'}) ${String(e.message).slice(0, 160)}`;

// 1. Audio : Gemini vs texte français OpenAI déjà validé.
const audio = [];
for (let i = 0; i < Math.min(Number(process.env.CHUNKS), job.chunks.length); i++) {
  const reference = job.transcript.find(t => t.index === i)?.text ?? '';
  try {
    const result = await provider.transcribe(await fs.readFile(path.join(dir, `${i}.m4a`)));
    audio.push({ index: i, openai: reference, gemini: result.text, wer: wer(reference, result.text), numbers: kept(reference, result.text) });
  } catch (e) {
    audio.push({ index: i, openai: reference, error: fail(e) }); console.log(`Bloc ${i} : ${fail(e)}`);
    if (i === 0) {
      // The server masks provider answers; show OpenRouter's own error once
      // (status and message only, never request content) to diagnose it.
      const { textProviderConfig, completionBody } = await import('/app/server/ai/provider.mjs');
      const config = textProviderConfig({ ...process.env, AI_PROVIDER: 'openrouter' });
      const bytes = await fs.readFile(path.join(dir, '0.m4a'));
      const r = await fetch(config.url, { method: 'POST', headers: { Authorization: `Bearer ${config.apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(completionBody(config, { model: process.env.VISIT_TRANSCRIPTION_MODEL || 'google/gemini-3.5-flash-lite', maxTokens: 256,
          messages: [{ role: 'user', content: [{ type: 'text', text: 'Transcris.' }, { type: 'input_audio', input_audio: { data: bytes.toString('base64'), format: 'm4a' } }] }] })) });
      const body = await r.json().catch(() => ({}));
      console.log(`  OpenRouter : HTTP ${r.status} ${String(body.error?.message ?? '').slice(0, 300)}`);
      break;
    }
  }
}
const ok = audio.filter(a => !a.error);
const avg = xs => xs.length ? xs.reduce((s, x) => s + x, 0) / xs.length : null;
console.log(`\nAudio Gemini : ${ok.length}/${audio.length} blocs transcrits.`);
if (ok.length) {
  console.log(`  Écart de mots avec OpenAI (WER) : ${(avg(ok.map(a => a.wer)) * 100).toFixed(1)} % en moyenne`);
  const n = ok.map(a => a.numbers).filter(x => x !== null);
  if (n.length) console.log(`  Nombres et mesures retrouvés : ${(avg(n) * 100).toFixed(0)} %`);
}

// 2. Manuscrits : Claude vs lecture OpenAI existante.
const pages = [];
for (const [i, page] of (job.context.handwritten ?? []).slice(0, Number(process.env.PAGES)).entries()) {
  try { pages.push({ section: page.section, page: page.page, openai: job.handwrittenText?.[i]?.text ?? '', claude: await provider.readHandwriting(page.image) }); }
  catch (e) { pages.push({ section: page.section, page: page.page, error: fail(e) }); console.log(`Page ${i} : ${fail(e)}`); }
}
console.log(`Manuscrits Claude : ${pages.filter(p => !p.error).length}/${pages.length} pages relues.`);

// 3. Rédaction : Claude Opus sur les mêmes sources (transcription OpenAI) que Luna.
let draft = null;
try {
  const sources = { ...job, facts: undefined, result: undefined };
  const facts = await provider.extractFacts(sources);
  let style = null;
  if (process.env.VISIT_STYLE_PROFILES_PATH) {
    try {
      const profiles = JSON.parse(await fs.readFile(process.env.VISIT_STYLE_PROFILES_PATH, 'utf8'));
      const norm = v => String(v).normalize('NFD').replace(/[̀-ͯ]/g, '').trim().toLowerCase();
      const p = Object.entries(profiles).find(([k, v]) => [k, ...(v.aliases ?? [])].some(n => norm(n) === norm(job.author)))?.[1];
      style = p?.sourceReview?.authorVerified === true ? p : null;
    } catch {}
  }
  draft = { facts: facts.facts.length, result: await provider.draft({ ...sources, facts }, style), luna: job.result };
  console.log(`Rédaction Claude : ${facts.facts.length} faits sourcés (Luna : ${job.facts?.facts?.length ?? '?'}), ${Object.keys(draft.result.sections).length} rubriques remplies (Luna : ${Object.keys(job.result?.sections ?? {}).length}).`);
} catch (e) { console.log(`Rédaction Claude : ${fail(e)}`); }

// Coût estimé : OpenRouter renvoie son coût ; Claude Opus 5.5 au tarif public 4 $ / 20 $ par million.
const openrouter = usage.filter(u => u.provider !== 'anthropic').reduce((s, u) => s + (u.cost ?? 0), 0);
const claude = usage.filter(u => u.provider === 'anthropic').reduce((s, u) => s + (u.promptTokens ?? 0) * 4e-6 + (u.completionTokens ?? 0) * 20e-6, 0);
const minutes = ok.reduce((s, a) => s + job.chunks[a.index].duration, 0) / 60;
console.log(`\nCoût de l'essai : OpenRouter ${openrouter.toFixed(3)} $ pour ${minutes.toFixed(0)} min d'audio` +
  (minutes ? ` (≈ ${(openrouter / minutes * 60).toFixed(2)} $ / heure)` : '') + `, Claude ≈ ${claude.toFixed(3)} $.`);

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const md = [`# Comparatif visite ${job.id} (${job.createdAt.slice(0, 10)})`, '', '## Audio : OpenAI (référence) / Gemini 3.5 Flash-Lite', '',
  ...audio.flatMap(a => [`### Bloc ${a.index}${a.error ? '' : ` : écart ${(a.wer * 100).toFixed(0)} %`}`, '', '**OpenAI**', '', a.openai, '', '**Gemini**', '', a.gemini ?? a.error, '']),
  '## Manuscrits : OpenAI / Claude', '',
  ...pages.flatMap(p => [`### ${p.section} p. ${p.page}`, '', '**OpenAI**', '', p.openai, '', '**Claude**', '', p.claude ?? p.error, '']),
  '## Rédaction : Luna (actuelle) / Claude Opus 5.5', '',
  ...(draft ? Object.keys({ ...draft.luna?.sections, ...draft.result.sections }).flatMap(k => [`### ${k}`, '', '**Luna**', '', draft.luna?.sections?.[k] ?? '(vide)', '', '**Claude**', '', draft.result.sections[k] ?? '(vide)', '']) : ['(échec)']),
].join('\n');
await fs.writeFile(`/out/${job.id}-${stamp}.md`, md, { mode: 0o600 });
await fs.writeFile(`/out/${job.id}-${stamp}.json`, JSON.stringify({ audio, pages, draft, usage }, null, 1), { mode: 0o600 });
console.log(`\nComparatif complet (contenu clinique) : /root/visit-compare/${job.id}-${stamp}.md`);
JS
