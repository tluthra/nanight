#!/usr/bin/env python3
"""Generate a signed Sparkle appcast from the final notarized release ZIP."""

import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def version_parts(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Expected a numeric version, got {value!r}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def validate_release(info, tag, previous_feed, public_key):
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if tag != f"v{version}":
        raise ValueError(f"Release tag {tag} does not match app version {version}")
    if info.get("SUPublicEDKey") != public_key:
        raise ValueError("The app's Sparkle public key does not match the signing key in Keychain")
    if not info.get("SUFeedURL", "").startswith("https://"):
        raise ValueError("The release app must use an HTTPS update feed")
    version_parts(version)
    version_parts(build)
    feed = ET.parse(previous_feed).getroot()
    if feed.tag != "rss" or feed.find("channel") is None:
        raise ValueError("The existing feed must be an RSS appcast")
    for item in feed.findall("./channel/item"):
        previous_build = item.findtext(f"{{{SPARKLE}}}version")
        previous_version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
        enclosure = item.find("enclosure")
        if enclosure is not None:
            previous_build = previous_build or enclosure.get(f"{{{SPARKLE}}}version")
            previous_version = previous_version or enclosure.get(f"{{{SPARKLE}}}shortVersionString")
        if previous_build is None or previous_version is None:
            raise ValueError("An existing feed item is missing version information")
        if version_parts(build) <= version_parts(previous_build):
            raise ValueError(f"Build {build} must be greater than published build {previous_build}")
        if version_parts(version) <= version_parts(previous_version):
            raise ValueError(f"Version {version} must be greater than published version {previous_version}")


def main():
    root = Path(__file__).resolve().parent.parent
    tag = sys.argv[1]
    archive = Path(os.environ.get("ZIP_PATH", root / "dist/Nanight.zip")).resolve()
    output = Path(os.environ["APPCAST_OUTPUT_DIR"]).resolve()
    previous = Path(os.environ.get("PREVIOUS_APPCAST", root / "appcast.xml")).resolve()
    repository = os.environ.get("GITHUB_REPOSITORY", "tluthra/nanight")
    derived = Path(os.environ.get("DERIVED_DATA", root / "build/DerivedData"))
    tools = Path(os.environ.get("SPARKLE_BIN", derived / "SourcePackages/artifacts/sparkle/Sparkle/bin"))
    account = os.environ.get("SPARKLE_KEY_ACCOUNT", "com.tanooj.Nanight")
    if not (tools / "generate_appcast").is_file():
        raise ValueError("Sparkle tools not found; build the app first or set SPARKLE_BIN")
    public_key = subprocess.check_output(
        [tools / "generate_keys", "--account", account, "-p"], text=True
    ).strip()

    with tempfile.TemporaryDirectory(prefix="nanight-appcast-") as temporary:
        work = Path(temporary)
        extracted = work / "extracted"
        subprocess.run(["ditto", "-x", "-k", archive, extracted], check=True)
        info = plistlib.loads((extracted / "Nanight.app/Contents/Info.plist").read_bytes())
        expected_feed = plistlib.loads((root / "Configuration/Info.plist").read_bytes())["SUFeedURL"]
        if info.get("SUFeedURL") != expected_feed:
            raise ValueError("The archived app's feed URL does not match Configuration/Info.plist")
        validate_release(info, tag, previous, public_key)
        updates = work / "updates"
        updates.mkdir()
        shutil.copy2(archive, updates / "Nanight.zip")
        shutil.copy2(previous, updates / "appcast.xml")
        (updates / "Nanight.txt").write_text(os.environ.get("RELEASE_NOTES", f"Nanight {tag}"))
        prefix = f"https://github.com/{repository}/releases/download/{tag}/"
        subprocess.run([
            tools / "generate_appcast", "--account", account,
            "--download-url-prefix", prefix, "--embed-release-notes",
            "--maximum-deltas", "0", updates,
        ], check=True)
        tree = ET.parse(updates / "appcast.xml")
        item = next(item for item in tree.findall("./channel/item")
                    if item.findtext(f"{{{SPARKLE}}}version") == info["CFBundleVersion"])
        enclosure = item.find("enclosure")
        if enclosure is None or enclosure.get("url") != prefix + "Nanight.zip":
            raise ValueError("Generated appcast does not point to the versioned release ZIP")
        if int(enclosure.get("length", "0")) != archive.stat().st_size:
            raise ValueError("Generated archive length does not match the release ZIP")
        signature = enclosure.get(f"{{{SPARKLE}}}edSignature")
        if not signature:
            raise ValueError("Generated update has no EdDSA signature")
        subprocess.run([tools / "sign_update", "--account", account,
                        "--verify", archive, signature], check=True)
        output.mkdir(parents=True, exist_ok=True)
        shutil.copy2(updates / "appcast.xml", output / "appcast.xml")
    print(f"Verified appcast: {output / 'appcast.xml'}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, StopIteration, ET.ParseError) as error:
        sys.exit(f"error: {error}")
