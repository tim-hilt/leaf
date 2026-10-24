#!/usr/bin/env bash
# Usage: scripts/install.sh <device-name|mac>
# Builds Leaf (Release) and installs it on a connected device, or into
# /Applications for "mac".
set -euo pipefail

config=Release
target="${1:?usage: $0 <device-name|mac>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/apple/build"
bundle_id=com.timhilt.leaf

cd "$root"
make apple-core apple-project

cd apple
if [[ "$target" == mac ]]; then
  xcodebuild build -quiet -project Leaf.xcodeproj -scheme Leaf -configuration "$config" \
    -destination 'platform=macOS' -derivedDataPath "$build" -allowProvisioningUpdates
  rm -rf /Applications/Leaf.app
  cp -R "$build/Build/Products/$config/Leaf.app" /Applications/
  open /Applications/Leaf.app
else
  xcodebuild build -quiet -project Leaf.xcodeproj -scheme Leaf -configuration "$config" \
    -destination "platform=iOS,name=$target" -derivedDataPath "$build" -allowProvisioningUpdates
  xcrun devicectl device install app --device "$target" \
    "$build/Build/Products/$config-iphoneos/Leaf.app"
  xcrun devicectl device process launch --device "$target" "$bundle_id"
fi
