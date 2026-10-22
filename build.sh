#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Build requires macOS with full Xcode and the iOS SDK. No TIPA was produced.' >&2
  exit 2
fi
for tool in xcodebuild xcrun ldid zip python3; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 2; }
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null
mkdir -p dist
rm -f dist/ValidationRelay.tipa dist/ValidationRelay.tipa.sha256
xcrun swiftc ValidationRelay/RelayProtocol.swift tests/ProtocolTests.swift -o dist/protocol-tests
./dist/protocol-tests
xcodebuild -project ValidationRelay.xcodeproj -scheme ValidationRelay \
  -configuration Release -derivedDataPath DerivedData/ValidationRelay \
  -destination 'generic/platform=iOS' \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  TARGETED_DEVICE_FAMILY=1 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' build
app='DerivedData/ValidationRelay/Build/Products/Release-iphoneos/ValidationRelay.app'
export RELAY_BUILD_APP="$PWD/$app"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
app = Path(os.environ['RELAY_BUILD_APP'])
info = plistlib.loads((app/'Info.plist').read_bytes())
assert info['MinimumOSVersion'] == '15.0', 'Unexpected deployment target'
assert info['CFBundleExecutable'] == 'ValidationRelay'
assert 'UIBackgroundModes' not in info, 'Unexpected background capability'
PY
xcrun lipo -verify_arch arm64 "$app/ValidationRelay"
ldid -SValidationRelay/ValidationRelay.entitlements \
  -Idev.jjtech.experiments.ValidationRelay "$app/ValidationRelay"
mkdir -p dist
ldid -e "$app/ValidationRelay" > dist/embedded-entitlements.plist
python3 - <<'PY'
import plistlib
from pathlib import Path
expected=plistlib.loads(Path('ValidationRelay/ValidationRelay.entitlements').read_bytes())
actual=plistlib.loads(Path('dist/embedded-entitlements.plist').read_bytes())
assert all(actual.get(k) == v for k,v in expected.items()), 'Required entitlements missing'
PY
stage="$(mktemp -d "${TMPDIR:-/tmp}/validation-relay.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
cp -R "$app" "$stage/Payload/ValidationRelay.app"
# Fresh archive every time; avoid preserving stale files from a previous build.
(cd "$stage" && zip -qry ValidationRelay.tipa Payload)
cp "$stage/ValidationRelay.tipa" dist/ValidationRelay.tipa
shasum -a 256 dist/ValidationRelay.tipa > dist/ValidationRelay.tipa.sha256
echo 'Created dist/ValidationRelay.tipa. Install and verify on the exact iOS 15 device before claiming compatibility.'
