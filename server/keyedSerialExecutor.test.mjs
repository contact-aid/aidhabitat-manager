import assert from 'node:assert/strict';
import test from 'node:test';
import { createKeyedSerialExecutor } from './keyedSerialExecutor.mjs';

test('same-key housing creations are serialized while unrelated keys can proceed', async () => {
  const run = createKeyedSerialExecutor();
  const events = [];
  let releaseFirst;
  const firstMayFinish = new Promise((resolve) => { releaseFirst = resolve; });

  const first = run('beneficiary-1', async () => {
    events.push('first:start');
    await firstMayFinish;
    events.push('first:end');
  });
  const second = run('beneficiary-1', async () => events.push('second'));
  const unrelated = run('beneficiary-2', async () => events.push('unrelated'));

  await unrelated;
  assert.deepEqual(events, ['first:start', 'unrelated']);
  releaseFirst();
  await Promise.all([first, second]);
  assert.deepEqual(events, ['first:start', 'unrelated', 'first:end', 'second']);
});

test('a failed mutation releases the next mutation for the same key', async () => {
  const run = createKeyedSerialExecutor();
  const first = run('beneficiary-1', async () => { throw new Error('synthetic'); });
  const second = run('beneficiary-1', async () => 'completed');
  await assert.rejects(first, /synthetic/);
  assert.equal(await second, 'completed');
});
