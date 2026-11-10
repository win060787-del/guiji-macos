#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_NUMBER="${NOVA_BUILD_NUMBER:-25}"
ARGS=()
ARCHIVE=dist/Guiji-1.0.0-${BUILD_NUMBER}.xcarchive
DERIVED="${NOVA_DERIVED_DATA:-$HOME/Library/Caches/NovaContextRelease/DerivedData-${BUILD_NUMBER}}"
if [[ "${1:-}" == "--unsigned" ]]; then
  ARGS+=(CODE_SIGNING_ALLOWED=NO)
  ARCHIVE=dist/Guiji-1.0.0-${BUILD_NUMBER}-unsigned.xcarchive
elif [[ "${1:-}" == "--distribution" ]]; then
  ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" DEVELOPMENT_TEAM=7DXNZ5SH9Z PROVISIONING_PROFILE_SPECIFIER=)
  ARCHIVE=dist/Guiji-1.0.0-${BUILD_NUMBER}-distribution.xcarchive
  DERIVED="${NOVA_DERIVED_DATA:-$HOME/Library/Caches/NovaContextRelease/DerivedData-${BUILD_NUMBER}}"
else
  ARGS+=(-allowProvisioningUpdates)
fi
xcodebuild -project NovaContext.xcodeproj -scheme NovaContext -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE" "${ARGS[@]}" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive
# This script creates an archive only. It never uploads or submits for review.
