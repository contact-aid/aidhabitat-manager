#!/usr/bin/env bash
# Executes the characterization against the exact historical application source.
set -euo pipefail
app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_dir="$(git -C "$app_dir" rev-parse --show-toplevel)"
base=a5b4d9fbe40579160a9290688a7707e7a3376c2c
scratch="$(mktemp -d /tmp/appergo-assist2-build64-XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
printf 'Exact iPad source: %s\n' "$base"
git -C "$repo_dir" archive "$base" aid_habitat_app | tar -x -C "$scratch"
mkdir -p "$scratch/aid_habitat_app/test/compatibility"
cp "$app_dir/test/compatibility/build64_sanitary_rooms_test.dart" "$scratch/aid_habitat_app/test/compatibility/"
cd "$scratch/aid_habitat_app"
flutter test --dart-define=LEGACY_BUILD64=true test/compatibility/build64_sanitary_rooms_test.dart
