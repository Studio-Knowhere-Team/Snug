import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GENERAL_SETTINGS_VIEW = REPO_ROOT / "Snug" / "Preferences" / "GeneralSettingsView.swift"
APP_PREFERENCES = REPO_ROOT / "Snug" / "Preferences" / "AppPreferences.swift"


class PocketToggleAppStorageIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.general_settings_text = GENERAL_SETTINGS_VIEW.read_text(encoding="utf-8")
        cls.app_preferences_text = APP_PREFERENCES.read_text(encoding="utf-8")

    def test_general_settings_declares_pocket_toggle_with_exact_app_storage_key(self) -> None:
        self.assertIn(
            '@AppStorage("isPocketEnabled") private var pocketEnabled = true',
            self.general_settings_text,
        )
        self.assertRegex(
            self.app_preferences_text,
            re.compile(r'static let isPocketEnabled = "isPocketEnabled"'),
        )

    def test_pocket_toggle_binds_directly_to_app_storage_value(self) -> None:
        self.assertRegex(
            self.general_settings_text,
            re.compile(
                r'Section \{\s*'
                r'Toggle\("Show Pocket below notch", isOn: \$pocketEnabled\)',
                re.MULTILINE,
            ),
        )
        self.assertNotIn(
            'Toggle("Show Pocket below notch", isOn: Binding(',
            self.general_settings_text,
        )
        self.assertNotIn("preferences.isPocketEnabled", self.general_settings_text)

    def test_pocket_toggle_change_notifies_preferences_callback(self) -> None:
        self.assertRegex(
            self.general_settings_text,
            re.compile(
                r'\.onChange\(of: pocketEnabled\) \{ _, _ in\s*'
                r'preferences\.onPreferencesChanged\?\(\)\s*'
                r'\}',
                re.MULTILINE,
            ),
        )

    def test_app_preferences_registers_pocket_enabled_default_true_for_restart_persistence(self) -> None:
        self.assertRegex(
            self.app_preferences_text,
            re.compile(
                r"UserDefaults\.standard\.register\(defaults: \[\s*"
                r".*?Keys\.isPocketEnabled: true,",
                re.MULTILINE | re.DOTALL,
            ),
        )


if __name__ == "__main__":
    unittest.main()
