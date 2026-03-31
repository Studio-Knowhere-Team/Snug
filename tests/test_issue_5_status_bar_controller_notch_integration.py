import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
STATUS_BAR_CONTROLLER = REPO_ROOT / "Snug" / "StatusBar" / "StatusBarController.swift"


class StatusBarControllerIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.status_bar_text = STATUS_BAR_CONTROLLER.read_text(encoding="utf-8")

    def test_issue_5_declares_coordinator_and_activation_lock_state(self) -> None:
        self.assertIn("private var notchDropdownCoordinator: NotchDropdownCoordinator?", self.status_bar_text)
        self.assertIn("private var isActivatingItem = false", self.status_bar_text)

    def test_setup_calls_setup_notch_dropdown_after_safe_left_x_calculation(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"private func setup\(\) \{\s*"
                r"calculateSafeLeftX\(\)\s*"
                r"setupNotchDropdown\(\)\s*"
                r"updateCollapseLength\(\)",
                re.MULTILINE,
            ),
        )

    def test_setup_notch_dropdown_is_guarded_by_has_notch_and_pocket_enabled_and_wires_activation_callback(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"private func setupNotchDropdown\(\) \{\s*"
                r"guard hasNotch, preferences\.isPocketEnabled else \{\s*"
                r"notchDropdownCoordinator\?\.stop\(\)\s*"
                r"notchDropdownCoordinator = nil\s*"
                r"return\s*"
                r"\}\s*"
                r"// Stop old coordinator before creating replacement.*?\s*"
                r"// overlapping event monitors during ARC deallocation window\.\s*"
                r"notchDropdownCoordinator\?\.stop\(\)\s*"
                r"notchDropdownCoordinator = nil\s*"
                r"let coordinator = NotchDropdownCoordinator\(\)\s*"
                r"coordinator\.onItemActivated = \{ \[weak self\] info in\s*"
                r"self\?\.activateHiddenItem\(info\)\s*"
                r"\}\s*"
                r"notchDropdownCoordinator = coordinator\s*"
                r"coordinator\.update\(items: cachedHiddenItemInfo, notchRect: cachedNotchRect\)",
                re.MULTILINE,
            ),
        )

    def test_update_notch_dropdown_items_forwards_cache_changes_via_update_items_only(self) -> None:
        match = re.search(
            r"private func updateNotchDropdownItems\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn("guard let notchDropdownCoordinator else { return }", body)
        self.assertIn("notchDropdownCoordinator.updateItems(cachedHiddenItemInfo)", body)
        self.assertNotIn("calculateNotchRect()", body)
        self.assertNotIn("update(items:", body)

    def test_collapse_menu_bar_resolves_items_updates_coordinator_and_starts_tracking(self) -> None:
        self.assertIn("cachedHiddenItemInfo = AccessibilityMenuBarHelper.resolveItems(for: cachedHiddenItems)", self.status_bar_text)
        self.assertIn("updateNotchDropdownItems()", self.status_bar_text)
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"updateCollapseLength\(\)\s*"
                r"separatorItem\.length = collapseLength\s*"
                r"if notchDropdownCoordinator == nil \{\s*"
                r"setupNotchDropdown\(\)\s*"
                r"\}\s*"
                r"notchDropdownCoordinator\?\.update\(items: cachedHiddenItemInfo, notchRect: cachedNotchRect\)\s*"
                r"isToggling = false",
                re.MULTILINE,
            ),
        )
        collapse_match = re.search(
            r"private func collapseMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(collapse_match)
        collapse_body = collapse_match.group("body")
        self.assertEqual(collapse_body.count("setupNotchDropdown()"), 1)
        recreate_window = re.search(
            r"separatorItem\.length = collapseLength\s*(?P<section>.*?)notchDropdownCoordinator\?\.update",
            collapse_body,
            re.DOTALL,
        )
        self.assertIsNotNone(recreate_window)
        recreate_section = recreate_window.group("section")
        self.assertNotIn("preferences.isPocketEnabled", recreate_section)
        self.assertNotIn("guard hasNotch", recreate_section)

    def test_expand_menu_bar_stops_coordinator_before_revealing_items(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"private func expandMenuBar\(\) \{.*?"
                r"isCollapsed = false\s*"
                r"updateToggleIcon\(\)\s*"
                r"notchDropdownCoordinator\?\.stop\(\)\s*"
                r"notchDropdownCoordinator = nil\s*"
                r".*?separatorItem\.length = NSStatusItem\.variableLength",
                re.MULTILINE | re.DOTALL,
            ),
        )

    def test_expand_and_collapse_keep_coordinator_lifecycle_statements_in_required_order(self) -> None:
        expand_match = re.search(
            r"private func expandMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(expand_match)
        expand_body = expand_match.group("body")
        self.assertLess(
            expand_body.index("notchDropdownCoordinator?.stop()"),
            expand_body.index("notchDropdownCoordinator = nil"),
        )
        self.assertLess(
            expand_body.index("notchDropdownCoordinator = nil"),
            expand_body.index("separatorItem.length = NSStatusItem.variableLength"),
        )

        collapse_match = re.search(
            r"private func collapseMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(collapse_match)
        collapse_body = collapse_match.group("body")
        self.assertLess(
            collapse_body.index("if notchDropdownCoordinator == nil {"),
            collapse_body.index("setupNotchDropdown()"),
        )
        self.assertLess(
            collapse_body.index("setupNotchDropdown()"),
            collapse_body.index("notchDropdownCoordinator?.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)"),
        )

    def test_context_menu_dismisses_panel_before_building_menu(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"private func showContextMenu\(\) \{\s*"
                r"notchDropdownCoordinator\?\.dismissPanel\(\)\s*"
                r"\s*let menu = NSMenu\(\)",
                re.MULTILINE,
            ),
        )

    def test_hidden_item_clicked_is_thin_wrapper_around_activate_hidden_item(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"@objc private func hiddenItemClicked\(_ sender: NSMenuItem\) \{\s*"
                r"guard let info = sender\.representedObject as\? HiddenItemInfo else \{ return \}\s*"
                r"activateHiddenItem\(info\)\s*"
                r"\}",
                re.MULTILINE,
            ),
        )

    def test_activate_hidden_item_uses_reentrancy_guard_and_resets_lock_on_completion_paths(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"func activateHiddenItem\(_ info: HiddenItemInfo\) \{\s*"
                r"guard !isActivatingItem else \{ return \}\s*"
                r"isActivatingItem = true",
                re.MULTILINE,
            ),
        )
        self.assertIn("notchDropdownCoordinator?.stop()", self.status_bar_text)
        self.assertGreaterEqual(self.status_bar_text.count("self.isActivatingItem = false"), 2)
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"if !pressed \{\s*"
                r"snugLog\(\" activateHiddenItem: AXPress failed for '%@'\", info\.name\)\s*"
                r"\}\s*"
                r"self\.isActivatingItem = false\s*"
                r"self\.autoCollapseIfNeeded\(\)",
                re.MULTILINE,
            ),
        )

    def test_screen_parameter_changes_dismiss_cancel_stop_clear_and_rebuild_in_required_order(self) -> None:
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
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ 0\.2\) \{ \[weak self\] in\s*"
                r"guard let self else \{ return \}\s*"
                r"if self\.isCollapsed \{\s*"
                r"self\.notchDropdownCoordinator\?\.update\(items: self\.cachedHiddenItemInfo, notchRect: self\.cachedNotchRect\)\s*"
                r"self\.postCollapseDiscovery\(\)\s*"
                r"\} else \{\s*"
                r"self\.refreshHiddenItemCache\(\)",
                re.MULTILINE,
            ),
        )

    def test_preference_changes_delegate_pocket_rebuild_and_teardown_to_setup_notch_dropdown(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"private func handlePreferencesChanged\(\) \{\s*"
                r"if preferences\.isAutoHide \{\s*"
                r"autoCollapseIfNeeded\(\)\s*"
                r"\} else \{\s*"
                r"autoHideTimer\?\.invalidate\(\)\s*"
                r"autoHideTimer = nil\s*"
                r"\}\s*"
                r"// Re-evaluate pocket state when toggled\s*"
                r"setupNotchDropdown\(\)\s*"
                r"\}",
                re.MULTILINE,
            ),
        )

    def test_setup_notch_dropdown_cleans_up_existing_coordinator_before_returning_when_pocket_disabled(self) -> None:
        setup_match = re.search(
            r"private func setupNotchDropdown\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(setup_match)
        setup_body = setup_match.group("body")
        self.assertIn("guard hasNotch, preferences.isPocketEnabled else {", setup_body)
        disabled_guard = re.search(
            r"guard hasNotch, preferences\.isPocketEnabled else \{\s*"
            r"notchDropdownCoordinator\?\.stop\(\)\s*"
            r"notchDropdownCoordinator = nil\s*"
            r"return",
            setup_body,
            re.MULTILINE,
        )
        self.assertIsNotNone(disabled_guard)


if __name__ == "__main__":
    unittest.main()
