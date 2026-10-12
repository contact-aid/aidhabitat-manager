import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Test the proposed shared-file patch only in a disposable copy. Never edit
// the checkout's generator, templates, or the other agents' worktrees.
export async function mobilityPdfSandbox() {
  const root = fileURLToPath(new URL('../../', import.meta.url));
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'appergo-mobility-pdf-'));
  const reports = path.join(directory, 'server/reports');
  await fs.mkdir(reports, { recursive: true });
  for (const name of ['generateVisitReport.mjs', 'mobilityAids.mjs', 'photoLayout.mjs', 'morbihanEligibleWorks.mjs']) {
    await fs.copyFile(path.join(root, 'server/reports', name), path.join(reports, name));
  }
  await fs.symlink(path.join(root, 'server/templates'), path.join(directory, 'server/templates'));
  await fs.symlink(await fs.realpath(path.join(root, 'node_modules')), path.join(directory, 'node_modules'));
  const patch = path.join(root, 'docs/compatibility/mobility-pdf-integration.patch');
  const source = await fs.readFile(path.join(reports, 'generateVisitReport.mjs'), 'utf8');
  const integrated = source.includes('applyMobilityAidsToReport({');
  if (!integrated) {
    execFileSync('git', ['apply', '--check', patch], { cwd: directory });
    execFileSync('git', ['apply', patch], { cwd: directory });
  }
  const candidatePath = integrated
    ? path.join(root, 'server/reports/generateVisitReport.mjs')
    : path.join(reports, 'generateVisitReport.mjs');
  const module = await import(pathToFileURL(candidatePath).href);
  return { ...module, dispose: () => fs.rm(directory, { recursive: true, force: true }) };
}
