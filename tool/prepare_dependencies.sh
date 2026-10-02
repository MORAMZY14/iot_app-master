#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

mode="${1:---refresh}"
if [[ "$mode" != "--refresh" && "$mode" != "--locked" ]]; then
  echo "Usage: bash tool/prepare_dependencies.sh [--refresh|--locked]" >&2
  exit 2
fi
if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is unavailable. Install the SDK version in .flutter-version first." >&2
  exit 127
fi

# CI mode avoids Flutter's cloud-environment metadata probe during SDK setup.
export CI=true
sdk_info="$(mktemp)"
trap 'rm -f "$sdk_info"' EXIT
flutter --version --machine > "$sdk_info"
python3 - "$sdk_info" <<'PY'
import json
import sys
from pathlib import Path

expected = Path('.flutter-version').read_text().strip()
actual = json.loads(Path(sys.argv[1]).read_text())['frameworkVersion']
if actual != expected:
    raise SystemExit(f'Expected Flutter {expected}; found {actual}. Use the pinned SDK.')
PY

flutter config --no-enable-swift-package-manager
if [[ "$mode" == "--locked" ]]; then
  flutter pub get --enforce-lockfile
else
  # Exact direct versions and the baseline lock preserve used package versions;
  # prune removed dependencies and recreate native registrants. Attach the
  # resolved lock to the build report, then enforce this actual resolved graph.
  flutter pub get
  flutter pub get --enforce-lockfile
fi
mkdir -p build/reports
flutter pub deps --json > build/reports/resolved-dependencies.json
cp pubspec.lock build/reports/pubspec.resolved.lock
python3 tool/verify_build_policy.py --resolved
