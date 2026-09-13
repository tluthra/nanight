# Nanight menu bar icon concepts

Three custom vector drawings share the exact same crescent geometry and placement:

- `nanight-default`: three five-point stars.
- `nanight-sound`: an eighth note on each side.
- `nanight-motion`: three motion strokes on each side.

These are review assets only. The app's SF Symbols and state mapping have not been changed.

## Files

- SVG: editable 24-unit vector masters.
- PDF: vector exports sized for a 22-point image.
- PNG: transparent black artwork at 22, 44, and 66 pixels, for 1x, 2x, and 3x.
- `preview.svg` and `preview.png`: enlarged designs and 22-point examples on light and dark backgrounds. View the SVG at 100% for the intended point size.

For future integration, use template rendering so macOS controls the icon color. Other states, including idle and simultaneous motion and sound, have not been designed or mapped yet.

## Regeneration

`generate.py` requires Python and CairoSVG. On this machine:

```sh
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib /tmp/nanight-icon-tools/bin/python outputs/menu-bar-icons/generate.py
```

The temporary Python environment can be recreated with `python3 -m venv /tmp/nanight-icon-tools` and `/tmp/nanight-icon-tools/bin/pip install cairosvg`.

## Verification

All exports regenerated successfully. The preview was visually inspected, including the stars, notes, and motion strokes on both backgrounds.

An app build was attempted with `xcodebuild -project Nanight.xcodeproj -scheme Nanight -configuration Debug -destination 'platform=macOS' -derivedDataPath build/IconPreviewDerivedData CODE_SIGNING_ALLOWED=NO build`. Dependency resolution was blocked by the sandbox network environment: `Could not resolve host: github.com` while fetching Logboard. No app source was modified for this work.
