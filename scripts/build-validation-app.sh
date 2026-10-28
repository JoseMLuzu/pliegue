#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(cd "${1:?Usage: build-validation-app.sh fixture-directory [swiftc options]}" && pwd)"
shift
cd "$project_root"
validation_bundle="$fixture_root/PliegueValidation.app"
validation_cache="$project_root/.build/validation-module-cache"
mkdir -p "$validation_cache" "$validation_bundle/Contents/MacOS" "$validation_bundle/Contents/Resources"
cp -R "$fixture_root/inputs" "$validation_bundle/Contents/Resources/"
cp "$fixture_root/manifest.json" "$validation_bundle/Contents/Resources/"
/usr/bin/python3 - "$validation_bundle/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(dict(CFBundleIdentifier='com.pliegue.validation', CFBundleName='PliegueValidation',
                      CFBundleDisplayName='Pliegue Validation', CFBundleExecutable='PliegueValidation',
                      CFBundlePackageType='APPL', CFBundleVersion='1', LSMinimumSystemVersion='14.0',
                      NSHighResolutionCapable=True, NSPrincipalClass='NSApplication'), output)
PY
swiftc "$@" -D VALIDATION_APP -parse-as-library -module-cache-path "$validation_cache" \
  Sources/PliegueCore/*.swift scripts/ValidateFiles.swift scripts/ValidateFilesApp.swift \
  -lz -o "$validation_bundle/Contents/MacOS/PliegueValidation"
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements Resources/Pliegue.entitlements "$validation_bundle"
codesign --verify --deep --strict "$validation_bundle"
printf '\nBuilt %s\n' "$validation_bundle"
