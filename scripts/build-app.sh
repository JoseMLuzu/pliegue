#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
build_options=(--configuration release --cache-path "$project_root/.build/cache" --config-path "$project_root/.build/config" --security-path "$project_root/.build/security")
export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$project_root/dist"
swift build "${build_options[@]}" "$@" --product Pliegue
binary_directory="$(swift build "${build_options[@]}" "$@" --show-bin-path)"
staging="$project_root/dist/.Pliegue-build-$$.app"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
install -m 755 "$binary_directory/Pliegue" "$staging/Contents/MacOS/Pliegue"
cp Resources/Info.plist "$staging/Contents/Info.plist"
iconset="$project_root/.build/AppIcon.iconset"
swift -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/GenerateIcon.swift "$iconset" "$project_root/Resources/AppIcon.icns"
cp Resources/AppIcon.icns "$staging/Contents/Resources/"
cp Resources/PrivacyInfo.xcprivacy "$staging/Contents/Resources/"
codesign --force --sign - --options runtime --timestamp=none --entitlements Resources/Pliegue.entitlements "$staging"
codesign --verify --strict "$staging"
if [ -d "$project_root/dist/Pliegue.app" ]; then rm -rf "$project_root/dist/Pliegue.app"; fi
mv "$staging" "$project_root/dist/Pliegue.app"
printf '\nBuilt %s\n' "$project_root/dist/Pliegue.app"
