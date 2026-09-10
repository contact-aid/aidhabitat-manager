import assert from 'node:assert/strict';
import test from 'node:test';
import { verifyLinkedWrite, verifyExistingLinkedTransport } from './verify-nocodb-linked-write.mjs';
import { STAGING_BASE } from './probe-nocodb-conditional-write.mjs';

for (const verify of [verifyLinkedWrite, verifyExistingLinkedTransport]) {
  test(`${verify.name} is offline by default and rejects another base`, async () => {
    const request = () => assert.fail('Unexpected network');
    assert.equal((await verify({ baseId: STAGING_BASE, request })).mode, 'dry-run');
    await assert.rejects(verify({ baseId: 'pskgbjythubfzv9', apply: true, request }));
  });
}
test('retained fixture verification refuses a replaced table before any write', async () => {
  const request = async (input) => {
    assert.equal(input.method, 'GET');
    return { title: 'business data' };
  };
  await assert.rejects(verifyExistingLinkedTransport({ baseId: STAGING_BASE, apply: true, request }));
});
