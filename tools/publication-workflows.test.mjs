import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('API publication is explicit and missing webhook blocks before image push', async () => {
  const workflow = await readFile('.github/workflows/build-deploy-api.yml', 'utf8');
  const preflight = workflow.indexOf('- name: Validate publication decision');
  const secretPreflight = workflow.indexOf('- name: Validate API deployment prerequisite');
  const login = workflow.indexOf('- name: Login to GitHub Container Registry');
  const image = workflow.indexOf('- name: Build & push Docker image');
  assert.ok(preflight > 0 && preflight < secretPreflight && secretPreflight < login && login < image);
  assert.match(workflow, /deploy_api=true requires publish_image=true/);
  assert.match(workflow, /Missing EASYPANEL_API_WEBHOOK; no image has been published/);
  assert.match(
    workflow,
    /push: \$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.publish_image \}\}/,
  );
  assert.match(
    workflow,
    /if: \$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.deploy_api \}\}/,
  );
  assert.match(workflow, /cancel-in-progress: false/);
});

test('web publication records provenance and requires an expected build', async () => {
  const workflow = await readFile('.github/workflows/flutter-web-build.yml', 'utf8');
  const check = workflow.indexOf('- name: Check web bundle');
  const secretPreflight = workflow.indexOf('- name: Validate web staging prerequisite');
  const publish = workflow.indexOf('- name: Publish prebuilt nginx image');
  assert.ok(check > 0 && check < secretPreflight && secretPreflight < publish);
  assert.match(workflow, /expected_build_number is required when publish_image=true/);
  assert.match(workflow, /deploy_staging=true requires publish_image=true/);
  assert.match(workflow, /Missing EASYPANEL_WEB_STAGING_DEPLOY_URL; no image has been published/);
  assert.match(workflow, /tools\/web-release-manifest\.mjs write/);
  assert.match(workflow, /--expected-git-sha "\$\{\{ github\.sha \}\}"/);
  assert.match(workflow, /retention-days: 14/);
  assert.match(workflow, /cancel-in-progress: false/);
});

test('critical web suite exercises vault migration and offline queue recovery', async () => {
  const script = await readFile('aid_habitat_app/tool/test_sync_critical.sh', 'utf8');
  assert.match(script, /test\/services\/web_vault_migration_test\.dart/);
  assert.match(script, /test\/services\/offline_persistence_test\.dart/);
});
