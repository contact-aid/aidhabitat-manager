// Opt-in, synthetic-only smoke test. A private env file supplies the key.
// macOS speech synthesis creates the source audio; no patient file is read.
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import sharp from 'sharp';
import { createVisitProvider } from '../server/visitAssistant.mjs';

if (process.env.VISIT_AI_LIVE_TEST !== 'true') {
  throw new Error('Set VISIT_AI_LIVE_TEST=true to authorize the synthetic OpenRouter smoke test.');
}
const run = promisify(execFile);
const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'visit-ai-synthetic-'));
try {
  await run('say', ['-v', 'Thomas', '-o', path.join(dir, 'visit.aiff'),
    'La personne ne rapporte aucune chute. Le seuil de la douche mesure douze centimètres. Elle souhaite rester dans son logement.']);
  await run('afconvert', ['-f', 'm4af', '-d', 'aac', path.join(dir, 'visit.aiff'), path.join(dir, 'visit.m4a')]);
  const provider = createVisitProvider();
  const text = await provider.transcribe(await fs.readFile(path.join(dir, 'visit.m4a')));
  assert.match(text, /aucune chute|pas.*chute/i);
  assert.match(text, /douze|12/i);
  const image = await sharp(Buffer.from('<svg width="900" height="240"><rect width="100%" height="100%" fill="white"/><text x="30" y="90" font-size="32">Seuil de douche : 12 cm.</text></svg>')).png().toBuffer();
  const handwritten = await provider.readHandwriting(`data:image/png;base64,${image.toString('base64')}`);
  assert.match(handwritten, /12/);
  const job = { transcript: [{ index: 0, startSeconds: 0, text }],
    context: { existingText: { 'Accessibilité-Notes': ['Texte clavier existant.'] }, handwritten: [] },
    handwrittenText: [{ section: 'Sanitaires-Notes', page: 0, text: handwritten }] };
  job.facts = await provider.extractFacts(job);
  assert.ok(job.facts.facts.length > 0);
  const result = await provider.draft(job, null);
  assert.match(result.sections['Contexte de vie-Autonomie'] ?? '', /aucune chute|pas.*chute/i);
  assert.match(result.sections['Sanitaires-Notes'] ?? '', /douze|12/i);
  assert.ok(!Object.values(result.sections).some(value => value.includes('Texte clavier existant.')));
  const answer = await provider.ask(job, 'Quelle est la hauteur du seuil de douche ?');
  assert.match(answer.answer, /12|douze/i);
  assert.deepEqual(answer.sources, [0]);
  console.log(JSON.stringify({ syntheticOnly: true, transcription: 'passed', printedImageReading: 'passed',
    factualExtraction: 'passed', drafting: 'passed', citedAnswer: 'passed' }));
} finally {
  await fs.rm(dir, { recursive: true, force: true });
}
