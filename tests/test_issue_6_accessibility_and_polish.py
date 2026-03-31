import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INFO_PLIST = REPO_ROOT / "Snug" / "Info.plist"
STATUS_BAR_CONTROLLER = REPO_ROOT / "Snug" / "StatusBar" / "StatusBarController.swift"
NOTCH_DROPDOWN_PANEL = REPO_ROOT / "Snug" / "StatusBar" / "NotchDropdownPanel.swift"
NOTCH_DROPDOWN_COORDINATOR = REPO_ROOT / "Snug" / "StatusBar" / "NotchDropdownCoordinator.swift"


class AccessibilityAndPolishIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.info_plist_text = INFO_PLIST.read_text(encoding="utf-8")
        cls.status_bar_text = STATUS_BAR_CONTROLLER.read_text(encoding="utf-8")
        cls.panel_text = NOTCH_DROPDOWN_PANEL.read_text(encoding="utf-8")
        cls.coordinator_text = NOTCH_DROPDOWN_COORDINATOR.read_text(encoding="utf-8")

    def test_accessibility_usage_description_discloses_mouse_tracking_and_dropdown_interaction(self) -> None:
        self.assertIn("<key>NSAccessibilityUsageDescription</key>", self.info_plist_text)
        self.assertIn(
            "<string>Snug needs Accessibility access to detect hidden menu bar items, "
            "track when your cursor enters the menu bar area, and interact with hidden items "
            "from the dropdown.</string>",
            self.info_plist_text,
        )

    def test_collapse_menu_bar_updates_coordinator_after_auto_hide(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"private func collapseMenuBar\(\) \{.*?"
                r"autoHideTimer\?\.invalidate\(\)\s*"
                r"autoHideTimer = nil\s*"
                r".*?separatorItem\.length = collapseLength\s*"
                r"if notchDropdownCoordinator == nil \{\s*"
                r"setupNotchDropdown\(\)\s*"
                r"\}\s*"
                r"notchDropdownCoordinator\?\.update\(items: cachedHiddenItemInfo, notchRect: cachedNotchRect\)",
                re.MULTILINE | re.DOTALL,
            ),
        )

    def test_panel_and_tracking_window_are_configured_to_follow_all_spaces(self) -> None:
        expected = "[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]"
        self.assertIn(f"panel.collectionBehavior = {expected}", self.panel_text)
        self.assertIn(f"window.collectionBehavior = {expected}", self.coordinator_text)

    def test_screen_parameter_changes_fully_reset_coordinator_and_rebuild_notch_state(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"@objc private func screenParametersChanged\(\) \{\s*"
                r"notchDropdownCoordinator\?\.dismissPanel\(\)\s*"
                r"autoHideTimer\?\.invalidate\(\)\s*"
                r"autoHideTimer = nil\s*"
                r"notchDropdownCoordinator\?\.stop\(\)\s*"
                r"notchDropdownCoordinator = nil\s*"
                r"cachedNaturalPositions = \[\]\s*"
                r"cachedHiddenItems = \[\]\s*"
                r"cachedHiddenItemInfo = \[\]\s*"
                r"cachedNotchRect = \.zero\s*"
                r"postCollapseItemCount = 0\s*"
                r"isActivatingItem = false\s*"
                r"calculateSafeLeftX\(\)\s*"
                r"updateCollapseLength\(\)\s*"
                r"setupNotchDropdown\(\)",
                re.MULTILINE,
            ),
        )
        self.assertIn("if self.isCollapsed {", self.status_bar_text)
        self.assertIn("self.postCollapseDiscovery()", self.status_bar_text)

    def test_non_notch_setup_disables_dropdown_and_preserves_safe_left_fallback(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"private func setupNotchDropdown\(\) \{\s*"
                r"guard hasNotch, preferences\.isPocketEnabled else \{\s*"
                r"notchDropdownCoordinator\?\.stop\(\)\s*"
                r"notchDropdownCoordinator = nil\s*"
                r"return",
                re.MULTILINE,
            ),
        )
        self.assertIn("safeLeftX = hasNotch ? notchRect.maxX : 80", self.status_bar_text)
        self.assertIn("private func showContextMenu() {", self.status_bar_text)
        self.assertIn("notchDropdownCoordinator?.dismissPanel()", self.status_bar_text)


if __name__ == "__main__":
    unittest.main()
