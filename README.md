<h1><img src="assets/readme-header.svg" alt="Nanight" width="250" height="64"></h1>

An unofficial native macOS menu bar app for viewing your Nanit camera from your desktop.

**[Download for Mac](https://github.com/tluthra/nanight/releases/latest/download/Nanight.zip)** · [All releases](https://github.com/tluthra/nanight/releases)

> Nanight is not affiliated with, endorsed by, or supported by Nanit.

## Get started

Requires **macOS 13 or newer** and a **Nanit account with access to a camera**.

1. Download and unzip `Nanight.zip`.
2. Move `Nanight.app` into Applications and open it.
3. Open Nanight from the menu bar and sign in with your Nanit account.

Email, password, and MFA sign-in are supported. Tokens are stored in the macOS Keychain.

## Features

- **Live video and audio** streamed from your Nanit camera.
- **Menu bar access** to keep your camera close while you work.
- **Motion and sound indicators** for activity at a glance.
- **macOS notifications** for camera activity.

## Build from source

You'll need Xcode in addition to the requirements above.

Open `Nanight.xcodeproj`, select the **Nanight** scheme, and run the app.

## Distribution

<details>
<summary><strong>Build a release ZIP</strong></summary>

```sh
./scripts/build-distributable.sh
```

The package is written to `dist/Nanight.zip`. Copy it to another Mac, unzip it, and move `Nanight.app` into Applications.

If the app is not signed with a Developer ID certificate and notarized by Apple, macOS may show an unidentified developer warning.

</details>

<details>
<summary><strong>Sign and notarize a build</strong></summary>

First, store your notary credentials:

```sh
xcrun notarytool store-credentials nanight-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Then build, notarize, staple, and repackage:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="nanight-notary" \
NOTARIZE=1 \
./scripts/build-distributable.sh
```

</details>

<details>
<summary><strong>Publish a GitHub release</strong></summary>

Increase both the marketing version and build number in Xcode, then commit and
push the code and matching `v<version>` tag. To build, notarize, and publish:

```sh
NOTARIZE=1 SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="nanight-notary" ./scripts/release-github.sh v0.0.5
```

By default, the release upload requires `Nanight.app` to be Developer ID signed with a valid stapled notarization ticket.

To upload an already-built, notarized ZIP:

```sh
BUILD=0 ZIP_PATH="$PWD/dist/v0.0.5/Nanight.zip" \
SPARKLE_BIN="$PWD/build/Release-v0.0.5/SourcePackages/artifacts/sparkle/Sparkle/bin" \
./scripts/release-github.sh v0.0.5
```

Keep the uploaded asset named `Nanight.zip` so the download link follows the latest release.

Stable releases generate and verify an Ed25519-signed update entry, upload the ZIP,
verify the downloaded bytes, and commit `appcast.xml` to `main` through the GitHub
API. The existing GitHub Pages site serves it at
`https://tluthra.github.io/nanight/appcast.xml`. Run `git pull --ff-only` afterward
to pick up the feed commit. Both version and build number must increase.

Drafts (`DRAFT=1`) and prereleases (`PRERELEASE=1`) never update the stable feed.
`ALLOW_UNNOTARIZED=1` is only accepted for these internal builds. Published ZIPs
are immutable; a retry must use identical bytes. If upload succeeds but feed
publishing fails, rerun with `BUILD=0` and the same ZIP.

</details>

## Automatic updates

Starting with 0.0.5, Nanight uses Sparkle 2. On second launch it asks whether to
check for updates automatically. Checks run daily while the app is open. Users
can change this in Settings or choose **Check for Updates…** from the menu at any
time. Installing an update always requires a click, so a background check does
not restart camera viewing. Users on an older version must download 0.0.5 once.

The Sparkle private key is stored in the releasing Mac's login Keychain under
account `com.tanooj.Nanight`. Only the public key is committed in
`Configuration/Info.plist`. `SPARKLE_KEY_ACCOUNT` can select another account when
using this workflow for a fork, whose public key and feed URL must also change.

Keep a secure backup of that key. Sparkle's `generate_keys --account
com.tanooj.Nanight -x <secure-backup-path>` exports it for a password manager or
encrypted backup; never commit the export. On another release Mac, import it
with `generate_keys --account com.tanooj.Nanight -f <secure-backup-path>`.

Run release metadata checks with
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests`.

## Important notes

Nanight uses unofficial Nanit API and streaming behavior learned from public community projects. It may stop working if Nanit changes its services.

Use at your own risk. **Do not use Nanight as a safety-critical baby monitor.**
