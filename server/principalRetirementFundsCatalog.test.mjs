import assert from 'node:assert/strict';
import test from 'node:test';

import { getPrincipalFundBranding } from './principalRetirementFundsCatalog.mjs';

test('CARSAT uses its dedicated official logo', () => {
  const branding = getPrincipalFundBranding('CARSAT');

  assert.equal(branding?.displayName, 'CARSAT');
  assert.equal(branding?.logoUrl, '/retirement-logos/principal/carsat.jpg');
});

test('the existing CNAV / CARSAT entry keeps its historical branding', () => {
  const branding = getPrincipalFundBranding('CNAV (Assurance retraite / CARSAT)');

  assert.equal(branding?.displayName, 'CNAV / CARSAT');
  assert.equal(branding?.logoUrl, '/retirement-logos/principal/cnav.png');
});
