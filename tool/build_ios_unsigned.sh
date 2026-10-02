#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "An unsigned iOS build still requires macOS and Xcode." >&2
  exit 2
fi

# The retained native plugins use CocoaPods. Disable automatic SwiftPM migration
# before Flutter prepares the Xcode project, including on a fresh CI runner.
flutter config --no-enable-swift-package-manager
mkdir -p build/reports
flutter build ios --release --no-codesign --verbose 2>&1 | tee build/reports/ios-build.log

app_bundle="build/ios/iphoneos/Runner.app"
if [[ ! -d "$app_bundle" ]]; then
  echo "Flutter did not produce the expected unsigned Runner.app bundle." >&2
  exit 1
fi
if codesign --display "$app_bundle" > build/reports/ios-signing.txt 2>&1; then
  echo "The iOS app unexpectedly contains a code signature." >&2
  exit 1
fi
python3 - <<'PY'
from pathlib import Path

report = Path('build/reports/ios-signing.txt').read_text()
if 'code object is not signed at all' not in report:
    raise SystemExit('Unable to confirm the iOS app is unsigned; inspect ios-signing.txt.')
if Path('build/ios/iphoneos/Runner.app/embedded.mobileprovision').exists():
    raise SystemExit('An unsigned app must not contain a provisioning profile.')
PY

# Preserve the native bundle layout for artifact download. This is a .app ZIP,
# not a signed IPA and not an App Store/TestFlight upload.
ditto -c -k --keepParent "$app_bundle" build/ios/SmartHome-unsigned-ios.zip
