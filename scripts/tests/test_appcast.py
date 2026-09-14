import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("appcast", Path(__file__).parents[1] / "generate-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.feed = Path(self.directory.name) / "appcast.xml"
        self.feed.write_text(f'''<rss xmlns:sparkle="{appcast.SPARKLE}"><channel><item>
            <sparkle:version>7</sparkle:version>
            <sparkle:shortVersionString>0.0.4</sparkle:shortVersionString>
            </item></channel></rss>''')
        self.info = {"CFBundleVersion": "8", "CFBundleShortVersionString": "0.0.5",
                     "SUPublicEDKey": "public-key", "SUFeedURL": "https://example.com/appcast.xml"}

    def validate(self):
        appcast.validate_release(self.info, "v0.0.5", self.feed, "public-key")

    def test_new_release(self):
        self.validate()

    def test_first_release(self):
        self.feed.write_text("<rss><channel/></rss>")
        self.validate()

    def test_rejects_reused_or_lower_build(self):
        for build in ["7", "7.0", "6"]:
            with self.subTest(build=build), self.assertRaisesRegex(ValueError, "must be greater"):
                self.info["CFBundleVersion"] = build
                self.validate()

    def test_rejects_unchanged_marketing_version(self):
        self.info["CFBundleShortVersionString"] = "0.0.4"
        with self.assertRaisesRegex(ValueError, "Version .* must be greater"):
            appcast.validate_release(self.info, "v0.0.4", self.feed, "public-key")

    def test_rejects_wrong_tag(self):
        with self.assertRaisesRegex(ValueError, "does not match app version"):
            appcast.validate_release(self.info, "v0.0.6", self.feed, "public-key")

    def test_rejects_wrong_signing_key(self):
        with self.assertRaisesRegex(ValueError, "does not match the signing key"):
            appcast.validate_release(self.info, "v0.0.5", self.feed, "another-key")

    def test_rejects_insecure_feed(self):
        self.info["SUFeedURL"] = "http://example.com/appcast.xml"
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            self.validate()

    def test_rejects_malformed_published_version(self):
        self.feed.write_text("<rss><channel><item/></channel></rss>")
        with self.assertRaisesRegex(ValueError, "missing version"):
            self.validate()

    def test_rejects_non_appcast_documents(self):
        self.feed.write_text("<html><body>Not an appcast</body></html>")
        with self.assertRaisesRegex(ValueError, "RSS appcast"):
            self.validate()

    def test_compares_numeric_versions(self):
        self.assertGreater(appcast.version_parts("10"), appcast.version_parts("9"))
        self.assertGreater(appcast.version_parts("0.0.10"), appcast.version_parts("0.0.9"))
        self.assertEqual(appcast.version_parts("8"), appcast.version_parts("8.0"))

    def test_rejects_nonnumeric_versions(self):
        for version in ["", "8beta", "8.1.2.3"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                appcast.version_parts(version)


if __name__ == "__main__":
    unittest.main()
