#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT="${PROJECT:-Nanight.xcodeproj}"
SCHEME="${SCHEME:-Nanight}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-Nanight}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/build/DerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
ZIP_PATH="${ZIP_PATH:-$DIST_DIR/$APP_NAME.zip}"
NOTARIZE="${NOTARIZE:-0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"

usage() {
  cat <<EOF
Build a distributable Nanight.app zip.

Usage:
  ./scripts/build-distributable.sh

Optional environment variables:
  SIGNING_IDENTITY                 Codesign identity, for example "Developer ID Application: Name (TEAMID)"
  DEVELOPMENT_TEAM                 Apple team ID to pass to xcodebuild
  PROVISIONING_PROFILE_SPECIFIER   Provisioning profile name, if needed
  NOTARIZE=1                       Submit the zip to Apple's notary service and staple the ticket
  NOTARY_KEYCHAIN_PROFILE          notarytool keychain profile name
  APPLE_ID                         Apple ID for notarytool, used when no keychain profile is set
  APPLE_TEAM_ID                    Apple team ID for notarytool
  APPLE_APP_PASSWORD               App specific password for notarytool
  DERIVED_DATA                     Build output root, defaults to build/DerivedData
  DIST_DIR                         Package output directory, defaults to dist
  ZIP_PATH                         Final zip path, defaults to dist/Nanight.zip
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$NOTARIZE" == "1" && -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="Developer ID Application"
fi

if [[ -z "$DEVELOPMENT_TEAM" && -n "$APPLE_TEAM_ID" ]]; then
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
fi

build_args=(
  -project "$ROOT_DIR/$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA"
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages"
  CLANG_MODULE_CACHE_PATH="$DERIVED_DATA/ModuleCache.noindex"
  build
)

if [[ -n "$SIGNING_IDENTITY" ]]; then
  build_args+=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
fi

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  build_args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

if [[ -n "$PROVISIONING_PROFILE_SPECIFIER" ]]; then
  build_args+=(PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_SPECIFIER")
fi

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

mkdir -p "$DERIVED_DATA" "$DIST_DIR"
rm -rf "$APP_PATH" "$ZIP_PATH"

echo "Building $APP_NAME.app..."
xcodebuild "${build_args[@]}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app not found at $APP_PATH" >&2
  exit 1
fi

echo "Verifying code signature..."
# A plain xcodebuild build does not re-sign Sparkle's nested helper tools.
# Sign from the inside out, retaining each helper's own entitlements.
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE_FRAMEWORK" && -n "$SIGNING_IDENTITY" ]]; then
  for helper in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
      --preserve-metadata=entitlements "$SPARKLE_FRAMEWORK/$helper"
  done
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    --preserve-metadata=entitlements "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Creating $ZIP_PATH..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Submitting $ZIP_PATH for notarization..."
  notary_result="$(mktemp "${TMPDIR:-/tmp}/nanight-notary.XXXXXX.json")"
  if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait --output-format json > "$notary_result"
  elif [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_APP_PASSWORD" ]]; then
    xcrun notarytool submit "$ZIP_PATH" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait \
      --output-format json > "$notary_result"
  else
    echo "error: set NOTARY_KEYCHAIN_PROFILE, or set APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD." >&2
    exit 1
  fi

  cat "$notary_result"
  notary_status="$(plutil -extract status raw -o - "$notary_result")"
  notary_id="$(plutil -extract id raw -o - "$notary_result")"
  rm -f "$notary_result"

  if [[ "$notary_status" != "Accepted" ]]; then
    echo "error: notarization status was $notary_status." >&2
    if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
      echo "Inspect the log with:" >&2
      echo "  xcrun notarytool log $notary_id --keychain-profile $NOTARY_KEYCHAIN_PROFILE" >&2
    else
      echo "Inspect the log with:" >&2
      echo "  xcrun notarytool log $notary_id --apple-id \"$APPLE_ID\" --team-id \"$APPLE_TEAM_ID\" --password \"APP_SPECIFIC_PASSWORD\"" >&2
    fi
    exit 1
  fi

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$APP_PATH"

  echo "Validating stapled notarization ticket..."
  xcrun stapler validate "$APP_PATH"

  echo "Recreating $ZIP_PATH with stapled app..."
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

  echo "Checking Gatekeeper assessment..."
  spctl -a -vvv -t execute "$APP_PATH"
fi

echo "Done: $ZIP_PATH"
