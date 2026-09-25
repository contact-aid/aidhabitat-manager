import assert from 'node:assert/strict';
import test from 'node:test';
import { readReportRecommendations } from './reports/reportRecommendationSource.mjs';

test('report reads the published recommendation list before stale legacy rows', async () => {
  let legacyReads = 0;
  const items = [{ id: '1' }, { id: '2' }, { id: '3' }];
  const result = await readReportRecommendations({
    readSnapshot: async () => ({ items }),
    readLegacy: async () => { legacyReads++; return [{ id: 'old' }]; },
  });
  assert.deepEqual(result, items);
  assert.equal(legacyReads, 0);
});

test('an explicitly empty published list does not resurrect old recommendations', async () => {
  const result = await readReportRecommendations({
    readSnapshot: async () => ({ items: [] }),
    readLegacy: async () => [{ id: 'old' }],
  });
  assert.deepEqual(result, []);
});

test('legacy recommendations remain available before the first publication', async () => {
  const result = await readReportRecommendations({
    readSnapshot: async () => null,
    readLegacy: async () => [{ id: 'old' }],
  });
  assert.deepEqual(result, [{ id: 'old' }]);
});
