# Nanight

Nanight is an unofficial native macOS menu bar app for viewing a Nanit camera from your desktop.

It is not affiliated with, endorsed by, or supported by Nanit.

## Features

- macOS menu bar app
- Nanit email, password, and MFA sign in
- Live RTMPS video and audio playback
- Motion and sound activity indicators
- Basic macOS notifications for activity

## Requirements

- macOS 13 or newer
- Xcode
- A Nanit account with access to a camera

## Running

Open `Nanight.xcodeproj` in Xcode, select the `Nanight` scheme, and run the app.

On first launch, sign in with your Nanit account. Tokens are stored in the macOS Keychain.

## Distribution

Build a Release app zip:

```sh
./scripts/build-distributable.sh
```

The package is written to `dist/Nanight.zip`. You can copy that zip to another Mac, unzip it, and move `Nanight.app` into Applications. If the app is not signed with a Developer ID certificate and notarized by Apple, macOS may show an unidentified developer warning on the other computer.

For a notarized Developer ID build, first store notary credentials:

```sh
xcrun notarytool store-credentials nanight-notary --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
```

Then build, notarize, staple, and repackage:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="nanight-notary" \
NOTARIZE=1 \
./scripts/build-distributable.sh
```

To create or update a GitHub Release and upload the zip:

```sh
gh auth login
./scripts/release-github.sh v1.0
```

By default, the release upload requires `Nanight.app` to be Developer ID signed with a valid stapled notarization ticket. For a smoother install on other Macs, run the notarized build command first, then upload that zip:

```sh
BUILD=0 ./scripts/release-github.sh v1.0
```

Set `ALLOW_UNNOTARIZED=1` only for internal test releases where you expect Gatekeeper warnings.

## Notes

This app uses unofficial Nanit API and streaming behavior learned from public community projects. It may stop working if Nanit changes its services.

Use at your own risk. Do not use this as a safety-critical baby monitor.
