#!/usr/bin/env bash
set -euo pipefail

# Builds FreeTalking in Release and packages it as a simple drag-to-Applications DMG.
# This is meant for local installs. If a Developer ID Application certificate is
# available it will be used. Otherwise, a stable local code-signing identity named
# "Ramblr Local Code Signing" is preferred so macOS TCC permissions keep matching
# across rebuilds. If neither exists, the app is signed ad-hoc and Accessibility
# permissions may need to be re-granted after every rebuild.
#
# Usage:
#   ./Scripts/local-dmg-build.sh [version]

SCHEME="Ramblr"
APP_NAME="FreeTalking"
CONFIGURATION="Release"
DERIVED_DATA_PATH="build-local"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
ENTITLEMENTS_PATH="Scripts/distribution-entitlements.plist"
PBXPROJ_PATH="Ramblr.xcodeproj/project.pbxproj"
VERSION="${1:-}"

cd "$(dirname "$0")/.."

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  cat >&2 <<EOF
Unable to find xcodebuild from a full Xcode installation.

Install Xcode, open it once to finish setup, then either:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

or run this script with:
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/local-dmg-build.sh
EOF
  exit 1
fi

if [ -z "${VERSION}" ]; then
  VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "${PBXPROJ_PATH}" | head -n 1)"
fi

if [ -z "${VERSION}" ]; then
  echo "Could not determine app version from ${PBXPROJ_PATH}" >&2
  exit 1
fi

SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
USE_HARDENED_RUNTIME="false"
if [ -z "${SIGNING_IDENTITY}" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
    | awk '!/CSSMERR/' \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
    | head -n 1)"
  if [ -n "${SIGNING_IDENTITY}" ]; then
    USE_HARDENED_RUNTIME="true"
  fi
fi

if [ -z "${SIGNING_IDENTITY}" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
    | awk '!/CSSMERR/' \
    | sed -n 's/.*"\(Ramblr Local Code Signing\)".*/\1/p' \
    | head -n 1)"
fi

if [ -z "${SIGNING_IDENTITY}" ]; then
  SIGNING_IDENTITY="-"
  echo "No Developer ID Application identity found; using ad-hoc signing."
elif [ "${USE_HARDENED_RUNTIME}" = "true" ]; then
  echo "Signing identity: ${SIGNING_IDENTITY} (Developer ID)"
else
  echo "Signing identity: ${SIGNING_IDENTITY} (local stable identity)"
fi

remove_signature_if_present() {
  local target="$1"
  if codesign --display --verbose=1 "${target}" >/dev/null 2>&1; then
    codesign --remove-signature "${target}"
  fi
}

sign_with_runtime() {
  local target="$1"
  remove_signature_if_present "${target}"

  local args=(--force)
  if [ "${USE_HARDENED_RUNTIME}" = "true" ]; then
    args+=(--options runtime --timestamp)
  fi
  args+=(--sign "${SIGNING_IDENTITY}" "${target}")
  codesign "${args[@]}"
}

sign_with_entitlements() {
  local target="$1"
  remove_signature_if_present "${target}"

  local args=(--force --entitlements "${ENTITLEMENTS_PATH}")
  if [ "${USE_HARDENED_RUNTIME}" = "true" ]; then
    args+=(--options runtime --timestamp)
  fi
  args+=(--sign "${SIGNING_IDENTITY}" "${target}")
  codesign "${args[@]}"
}

sign_bundled_media_adapter() {
  local app_bundle_path="$1"
  local adapter_path="${app_bundle_path}/Contents/Resources/MediaRemoteAdapter.dylib"

  if [ ! -f "${adapter_path}" ]; then
    echo "MediaRemoteAdapter.dylib not found inside the app bundle." >&2
    echo "Install it before building FreeTalking: brew install media-control" >&2
    exit 1
  fi

  sign_with_runtime "${adapter_path}"
}

BUILD_CMD=(xcodebuild
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  CODE_SIGN_STYLE=Manual
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  build)

echo "Building ${APP_NAME} (${CONFIGURATION})..."
if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  "${BUILD_CMD[@]}" | xcbeautify
else
  "${BUILD_CMD[@]}"
fi

if [ ! -d "${APP_PATH}" ]; then
  echo "Built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "Signing app bundle..."
sign_bundled_media_adapter "${APP_PATH}"
sign_with_entitlements "${APP_PATH}/Contents/MacOS/${APP_NAME}"
sign_with_entitlements "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

DMG_ROOT="dist/dmg-root"
DMG_PATH="dist/FreeTalking-${VERSION}-macos.dmg"

echo "Creating ${DMG_PATH}..."
rm -rf "${DMG_ROOT}" "${DMG_PATH}"
mkdir -p "${DMG_ROOT}" dist
ditto "${APP_PATH}" "${DMG_ROOT}/${APP_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

hdiutil verify "${DMG_PATH}"

echo
echo "Done: ${DMG_PATH}"
