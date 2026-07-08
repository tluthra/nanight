#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${APP_NAME:-Nanight}"
ZIP_PATH="${ZIP_PATH:-$ROOT_DIR/dist/$APP_NAME.zip}"
BUILD="${BUILD:-1}"
DRAFT="${DRAFT:-0}"
PRERELEASE="${PRERELEASE:-0}"
ALLOW_UNNOTARIZED="${ALLOW_UNNOTARIZED:-0}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
RELEASE_TAG="${RELEASE_TAG:-${1:-}}"
RELEASE_TITLE="${RELEASE_TITLE:-$APP_NAME $RELEASE_TAG}"
RELEASE_NOTES="${RELEASE_NOTES:-Release build of $APP_NAME.}"

usage() {
  cat <<EOF
Build Nanight.zip and upload it to a GitHub Release.

Usage:
  ./scripts/release-github.sh v1.0

Optional environment variables:
  RELEASE_TAG          Release tag. Defaults to the first argument.
  RELEASE_TITLE        Release title. Defaults to "Nanight <tag>".
  RELEASE_NOTES        Release notes text.
  GITHUB_REPOSITORY    owner/repo override for gh, for example "tanooj/Nanight".
  BUILD=0              Skip the build step and upload the existing zip.
  DRAFT=1              Create a draft release when the release does not exist.
  PRERELEASE=1         Mark a newly created release as a prerelease.
  ALLOW_UNNOTARIZED=1  Upload even if the app is not stapled and notarized.
  ZIP_PATH             Zip to upload. Defaults to dist/Nanight.zip.

This script requires the GitHub CLI. Run "gh auth login" before using it.
EOF
}

validate_zip_for_gatekeeper() {
  local temp_dir
  local app_path

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/nanight-release.XXXXXX")"

  ditto -x -k "$ZIP_PATH" "$temp_dir"
  app_path="$(find "$temp_dir" -maxdepth 2 -name "$APP_NAME.app" -type d -print -quit)"

  if [[ -z "$app_path" ]]; then
    echo "error: $APP_NAME.app was not found inside $ZIP_PATH" >&2
    rm -rf "$temp_dir"
    return 1
  fi

  if ! codesign --verify --deep --strict --verbose=2 "$app_path"; then
    rm -rf "$temp_dir"
    return 1
  fi

  if [[ "$ALLOW_UNNOTARIZED" == "1" ]]; then
    echo "Skipping notarization preflight because ALLOW_UNNOTARIZED=1."
    rm -rf "$temp_dir"
    return
  fi

  if ! xcrun stapler validate "$app_path"; then
    echo "error: $APP_NAME.app does not have a valid stapled notarization ticket." >&2
    echo "Run ./scripts/build-distributable.sh with NOTARIZE=1, then upload with BUILD=0." >&2
    rm -rf "$temp_dir"
    return 1
  fi

  rm -rf "$temp_dir"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$RELEASE_TAG" ]]; then
  usage >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: GitHub CLI not found. Install gh and run gh auth login." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Run gh auth login and try again." >&2
  exit 1
fi

gh_repo() {
  if [[ -n "$GITHUB_REPOSITORY" ]]; then
    gh "$@" -R "$GITHUB_REPOSITORY"
  else
    gh "$@"
  fi
}

if [[ "$BUILD" == "1" ]]; then
  "$ROOT_DIR/scripts/build-distributable.sh"
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: zip not found at $ZIP_PATH" >&2
  echo "Run ./scripts/build-distributable.sh first, or set ZIP_PATH." >&2
  exit 1
fi

validate_zip_for_gatekeeper

asset_label="$APP_NAME.zip"

if gh_repo release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "Release $RELEASE_TAG already exists. Uploading $asset_label with clobber..."
  gh_repo release upload "$RELEASE_TAG" "$ZIP_PATH#$asset_label" --clobber
else
  create_args=(
    release create "$RELEASE_TAG"
    "$ZIP_PATH#$asset_label"
    --title "$RELEASE_TITLE"
    --notes "$RELEASE_NOTES"
  )

  if [[ "$DRAFT" == "1" ]]; then
    create_args+=(--draft)
  fi

  if [[ "$PRERELEASE" == "1" ]]; then
    create_args+=(--prerelease)
  fi

  echo "Creating release $RELEASE_TAG and uploading $asset_label..."
  gh_repo "${create_args[@]}"
fi

echo "Done: $RELEASE_TAG"
