#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-Nanight}"
ZIP_PATH="${ZIP_PATH:-${DIST_DIR:-$ROOT_DIR/dist}/$APP_NAME.zip}"
BUILD="${BUILD:-1}"
DRAFT="${DRAFT:-0}"
PRERELEASE="${PRERELEASE:-0}"
ALLOW_UNNOTARIZED="${ALLOW_UNNOTARIZED:-0}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
RELEASE_TAG="${RELEASE_TAG:-${1:-}}"
RELEASE_TITLE="${RELEASE_TITLE:-$APP_NAME $RELEASE_TAG}"
RELEASE_NOTES="${RELEASE_NOTES:-Release build of $APP_NAME.}"
FEED_BRANCH="main"

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
  SPARKLE_BIN          Directory containing generate_appcast and sign_update.
  SPARKLE_KEY_ACCOUNT  Keychain account, defaults to com.tanooj.Nanight.

Push the release commit and tag first. Stable releases also update appcast.xml
on main for GitHub Pages. Pull main afterward to pick up that feed commit.
Drafts and prereleases never change the stable feed.

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

  local app_version
  app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")"
  if [[ "$RELEASE_TAG" != "v$app_version" ]]; then
    echo "error: tag $RELEASE_TAG does not match app version $app_version." >&2
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

  if ! spctl -a -t execute "$app_path"; then
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

if [[ "$ALLOW_UNNOTARIZED" == "1" && "$DRAFT" == "0" && "$PRERELEASE" == "0" ]]; then
  echo "error: unnotarized builds must be drafts or prereleases." >&2
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

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  GITHUB_REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
export GITHUB_REPOSITORY ZIP_PATH RELEASE_NOTES

release_work="$(mktemp -d "${TMPDIR:-/tmp}/nanight-publish.XXXXXX")"
trap 'rm -rf "$release_work"' EXIT

publish_feed=0
if [[ "$DRAFT" == "0" && "$PRERELEASE" == "0" ]]; then
  publish_feed=1
  # Read through the API so a stale Pages cache cannot hide a newer release.
  gh api "repos/$GITHUB_REPOSITORY/pages" > "$release_work/pages.json"
  gh api "repos/$GITHUB_REPOSITORY/contents/appcast.xml?ref=$FEED_BRANCH" > "$release_work/feed.json"
  python3 - "$release_work" "$ROOT_DIR/Configuration/Info.plist" <<'PY'
import base64, json, pathlib, plistlib, sys
work = pathlib.Path(sys.argv[1])
pages = json.loads((work / 'pages.json').read_text())
info = plistlib.loads(pathlib.Path(sys.argv[2]).read_bytes())
assert pages['source'] == {'branch': 'main', 'path': '/'}, 'Expected Pages to serve main at /'
assert pages['html_url'].rstrip('/') + '/appcast.xml' == info['SUFeedURL'], 'Pages URL does not match app feed'
feed = json.loads((work / 'feed.json').read_text())
(work / 'previous.xml').write_bytes(base64.b64decode(feed['content']))
PY
fi

if [[ "$BUILD" == "1" ]]; then
  "$ROOT_DIR/scripts/build-distributable.sh"
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: zip not found at $ZIP_PATH" >&2
  echo "Run ./scripts/build-distributable.sh first, or set ZIP_PATH." >&2
  exit 1
fi

validate_zip_for_gatekeeper

if [[ "$publish_feed" == "1" ]]; then
  PREVIOUS_APPCAST="$release_work/previous.xml" APPCAST_OUTPUT_DIR="$release_work/generated" \
    python3 "$ROOT_DIR/scripts/generate-appcast.py" "$RELEASE_TAG"
fi

asset_label="$APP_NAME.zip"

if gh_repo release view "$RELEASE_TAG" >/dev/null 2>&1; then
  existing_draft="$(gh_repo release view "$RELEASE_TAG" --json isDraft --jq .isDraft)"
  existing_prerelease="$(gh_repo release view "$RELEASE_TAG" --json isPrerelease --jq .isPrerelease)"
  if [[ "$publish_feed" == "1" && ( "$existing_draft" == "true" || "$existing_prerelease" == "true" ) ]]; then
    echo "error: the existing release is a draft or prerelease; it cannot enter the stable feed." >&2
    exit 1
  fi
  if [[ "$existing_draft" == "true" ]]; then
    gh_repo release upload "$RELEASE_TAG" "$ZIP_PATH#$asset_label" --clobber
  else
    # Published archives are immutable: replacing one breaks existing signatures.
    gh_repo release download "$RELEASE_TAG" --pattern "$asset_label" --dir "$release_work/download"
    if ! cmp -s "$ZIP_PATH" "$release_work/download/$asset_label"; then
      echo "error: this release already has a different ZIP. Publish a new version." >&2
      exit 1
    fi
  fi
else
  create_args=(
    release create "$RELEASE_TAG"
    "$ZIP_PATH#$asset_label"
    --title "$RELEASE_TITLE"
    --notes-file "$release_work/notes.txt"
    --verify-tag
  )

  if [[ "$DRAFT" == "1" ]]; then
    create_args+=(--draft)
  fi

  if [[ "$PRERELEASE" == "1" ]]; then
    create_args+=(--prerelease)
  fi

  echo "Creating release $RELEASE_TAG and uploading $asset_label..."
  printf '%s\n' "$RELEASE_NOTES" > "$release_work/notes.txt"
  gh_repo "${create_args[@]}"
fi

if [[ "$publish_feed" == "1" ]]; then
  # Verify the hosted bytes before advertising them to installed apps.
  mkdir -p "$release_work/verify"
  gh_repo release download "$RELEASE_TAG" --pattern "$asset_label" --dir "$release_work/verify"
  cmp "$ZIP_PATH" "$release_work/verify/$asset_label"
  python3 - "$release_work" "$RELEASE_TAG" "$FEED_BRANCH" <<'PY'
import base64, json, pathlib, sys
work = pathlib.Path(sys.argv[1])
previous = json.loads((work / 'feed.json').read_text())
request = {
    'message': f'Publish update feed for {sys.argv[2]}',
    'branch': sys.argv[3],
    'sha': previous['sha'],
    'content': base64.b64encode((work / 'generated/appcast.xml').read_bytes()).decode(),
}
(work / 'publish.json').write_text(json.dumps(request))
PY
  gh api --method PUT "repos/$GITHUB_REPOSITORY/contents/appcast.xml" \
    --input "$release_work/publish.json" --jq .commit.html_url
  echo "Update feed committed to $FEED_BRANCH. GitHub Pages will deploy it shortly."
fi

echo "Done: $RELEASE_TAG"
