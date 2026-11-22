#!/usr/bin/env bash
set -euo pipefail

# Builds FreeTalking in Release, signs it with a Developer ID, and installs it
# at /Applications/FreeTalking.app.

SCHEME="Ramblr"
APP_NAME="FreeTalking"
CONFIGURATION="Release"
DERIVED_DATA_PATH="build-local"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_NAME}.app"
ENTITLEMENTS_PATH="Scripts/distribution-entitlements.plist"

cd "$(dirname "$0")/.."

command -v trash >/dev/null 2>&1 || {
  echo "The 'trash' CLI is required. Install with: brew install trash" >&2
  exit 1
}

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
  echo "No valid signing identity found; using ad-hoc signing."
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

sign_bundled_media_adapter() {
  local app_bundle_path="$1"
  local adapter_path="${app_bundle_path}/Contents/Resources/MediaRemoteAdapter.dylib"

  if [ ! -f "${adapter_path}" ]; then
    echo "MediaRemoteAdapter.dylib not found inside the app bundle." >&2
    echo "Install media-control before building FreeTalking: brew install media-control" >&2
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

echo "Building ${APP_NAME} (${CONFIGURATION})…"
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

echo "Signing with Developer ID…"
sign_bundled_media_adapter "${APP_PATH}"

APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${APP_NAME}"
remove_signature_if_present "${APP_EXECUTABLE_PATH}"
SIGN_EXECUTABLE_ARGS=(--force --entitlements "${ENTITLEMENTS_PATH}")
if [ "${USE_HARDENED_RUNTIME}" = "true" ]; then
  SIGN_EXECUTABLE_ARGS+=(--options runtime --timestamp)
fi
SIGN_EXECUTABLE_ARGS+=(--sign "${SIGNING_IDENTITY}" "${APP_EXECUTABLE_PATH}")
codesign "${SIGN_EXECUTABLE_ARGS[@]}"

remove_signature_if_present "${APP_PATH}"
SIGN_APP_ARGS=(--force --entitlements "${ENTITLEMENTS_PATH}")
if [ "${USE_HARDENED_RUNTIME}" = "true" ]; then
  SIGN_APP_ARGS+=(--options runtime --timestamp)
fi
SIGN_APP_ARGS+=(--sign "${SIGNING_IDENTITY}" "${APP_PATH}")
codesign "${SIGN_APP_ARGS[@]}"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null

echo "Stopping any running ${APP_NAME}…"
pkill -x "${APP_NAME}" 2>/dev/null || true

if [ -e "${INSTALL_PATH}" ]; then
  echo "Trashing old ${INSTALL_PATH}…"
  trash "${INSTALL_PATH}"
fi

echo "Installing to ${INSTALL_PATH}…"
cp -R "${APP_PATH}" "${INSTALL_PATH}"

echo "Launching ${INSTALL_PATH}…"
open "${INSTALL_PATH}"

echo
echo "Installed:"
codesign -dv --verbose=4 "${INSTALL_PATH}" 2>&1 \
  | sed -n 's/^Identifier=/  Identifier: /p; s/^Authority=/  Authority: /p' \
  | head -n 3
