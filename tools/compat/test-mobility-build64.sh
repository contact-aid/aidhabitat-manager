#!/usr/bin/env bash
set -euo pipefail
repo_root="$(git rev-parse --show-toplevel)"
build64=a5b4d9fbe40579160a9290688a7707e7a3376c2c
snapshot="$(mktemp -d /tmp/appergo-mobility-build64.XXXXXX)"
git -C "$repo_root" archive "$build64" aid_habitat_app | tar -x -C "$snapshot"
mkdir -p "$snapshot/aid_habitat_app/test/compat"
cp "$repo_root/aid_habitat_app/test/compat/mobility_build64_test.dart" "$snapshot/aid_habitat_app/test/compat/"
printf 'Build 64 source: %s\nSnapshot: %s\n' "$build64" "$snapshot"
cd "$snapshot/aid_habitat_app"
flutter test --reporter expanded test/compat/mobility_build64_test.dart
