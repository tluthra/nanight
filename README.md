# Nanight

Nanight is an unofficial native macOS menu bar app for viewing a Nanit camera from your desktop.

It is not affiliated with, endorsed by, or supported by Nanit.

## Features

- macOS menu bar app
- Nanit email, password, and MFA sign in
- Live RTMPS video playback
- Audio while the video popover is open
- Mute control
- Motion and sound activity indicators
- Pinch to zoom and two-finger pan on the video
- Basic macOS notifications for activity

## Requirements

- macOS 13 or newer
- Xcode
- A Nanit account with access to a camera

## Running

Open `Nanight.xcodeproj` in Xcode, select the `Nanight` scheme, and run the app.

On first launch, sign in with your Nanit account. Tokens are stored in the macOS Keychain.

## Notes

This app uses unofficial Nanit API and streaming behavior learned from public community projects. It may stop working if Nanit changes its services.

Use at your own risk. Do not use this as a safety-critical baby monitor.
