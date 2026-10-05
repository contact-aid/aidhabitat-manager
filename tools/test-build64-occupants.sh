#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sha=a5b4d9fbe40579160a9290688a7707e7a3376c2c
scratch="$(mktemp -d "${TMPDIR:-/tmp}/appergo-build64-occupants.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# No worktree mutation, no .env, no device/build: export the exact historical sources.
git -C "$repo_dir" archive "$sha" aid_habitat_app | tar -x -C "$scratch"
cp "$repo_dir/compatibility/occupants/build64_occupants_test.dart" "$scratch/aid_habitat_app/test/build64_occupants_test.dart"
cd "$scratch/aid_habitat_app"
flutter test test/build64_occupants_test.dart --reporter expanded
