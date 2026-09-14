<h1><img src="Nanight/Assets.xcassets/AppIcon.appiconset/nanight-icon-128.png" alt="" width="56" height="56" align="middle"> Nanight</h1>

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

To create or update a release and upload the ZIP, substitute your release tag for `v1.0`:

```sh
gh auth login
./scripts/release-github.sh v1.0
```

By default, the release upload requires `Nanight.app` to be Developer ID signed with a valid stapled notarization ticket.

To upload an already-built, notarized ZIP:

```sh
BUILD=0 ./scripts/release-github.sh v1.0
```

Keep the uploaded asset named `Nanight.zip` so the download link follows the latest release.

Set `ALLOW_UNNOTARIZED=1` only for internal test releases where you expect Gatekeeper warnings.

</details>

## Important notes

Nanight uses unofficial Nanit API and streaming behavior learned from public community projects. It may stop working if Nanit changes its services.

Use at your own risk. **Do not use Nanight as a safety-critical baby monitor.**
