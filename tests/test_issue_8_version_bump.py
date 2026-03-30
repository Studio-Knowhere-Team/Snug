import plistlib
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_YML = REPO_ROOT / "project.yml"
INFO_PLIST = REPO_ROOT / "Snug" / "Info.plist"
ABOUT_VIEW = REPO_ROOT / "Snug" / "Preferences" / "AboutSettingsView.swift"
BUNDLE_EXTENSION = REPO_ROOT / "Snug" / "Extensions" / "Bundle+Version.swift"


class VersionBumpIssueTests(unittest.TestCase):
    def test_project_config_bumps_marketing_and_build_versions(self) -> None:
        project_text = PROJECT_YML.read_text(encoding="utf-8")

        self.assertRegex(project_text, r'MARKETING_VERSION:\s*"1\.1"')
        self.assertRegex(project_text, r'CURRENT_PROJECT_VERSION:\s*"3"')
        self.assertNotIn('MARKETING_VERSION: "1.0.1"', project_text)
        self.assertNotIn('CURRENT_PROJECT_VERSION: "2"', project_text)

    def test_info_plist_uses_generated_version_variables(self) -> None:
        with INFO_PLIST.open("rb") as plist_file:
            plist = plistlib.load(plist_file)

        self.assertEqual(plist["CFBundleShortVersionString"], "$(MARKETING_VERSION)")
        self.assertEqual(plist["CFBundleVersion"], "$(CURRENT_PROJECT_VERSION)")

    def test_bundle_extension_reads_short_version_string(self) -> None:
        bundle_extension_text = BUNDLE_EXTENSION.read_text(encoding="utf-8")

        self.assertIn('infoDictionary?["CFBundleShortVersionString"] as? String', bundle_extension_text)
        self.assertIn("var releaseVersionNumber: String?", bundle_extension_text)

    def test_about_view_uses_bundle_release_version_in_version_label(self) -> None:
        about_view_text = ABOUT_VIEW.read_text(encoding="utf-8")

        self.assertIn("if let version = Bundle.main.releaseVersionNumber", about_view_text)
        self.assertIn('Text("Version \\(version)")', about_view_text)
        self.assertNotRegex(about_view_text, r'Version 1(?:\.0\.1|\.1)')


if __name__ == "__main__":
    unittest.main()
