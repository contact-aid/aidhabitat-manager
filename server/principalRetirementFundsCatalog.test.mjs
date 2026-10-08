import assert from 'node:assert/strict';
import test from 'node:test';

import { getPrincipalFundBranding } from './principalRetirementFundsCatalog.mjs';

test('CARSAT uses its dedicated official logo', () => {
  const branding = getPrincipalFundBranding('CARSAT');

  assert.equal(branding?.displayName, 'CARSAT');
  assert.equal(branding?.logoUrl, '/retirement-logos/principal/carsat.jpg');
});

test('CNAV keeps its logo with the Assurance retraite label', () => {
  const branding = getPrincipalFundBranding('CNAV (Assurance retraite)');

  assert.equal(branding?.displayName, 'CNAV');
  assert.equal(branding?.logoUrl, '/retirement-logos/principal/cnav.png');
});

test('the previous CNAV label remains a compatible branding alias', () => {
  const branding = getPrincipalFundBranding('CNAV (Assurance retraite / CARSAT)');

  assert.equal(branding?.logoUrl, '/retirement-logos/principal/cnav.png');
});
