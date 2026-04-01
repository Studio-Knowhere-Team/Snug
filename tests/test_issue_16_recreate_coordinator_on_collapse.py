import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
STATUS_BAR_CONTROLLER = REPO_ROOT / "Snug" / "StatusBar" / "StatusBarController.swift"


class RecreateCoordinatorOnCollapseIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.status_bar_text = STATUS_BAR_CONTROLLER.read_text(encoding="utf-8")

    def test_issue_16_bugfix_recreates_coordinator_before_collapse_update_when_nil(self) -> None:
        collapse_match = re.search(
            r"private func collapseMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(collapse_match)
        collapse_body = collapse_match.group("body")

        self.assertIn("if notchDropdownCoordinator == nil {", collapse_body)
        self.assertIn("setupNotchDropdown()", collapse_body)
        self.assertIn(
            "notchDropdownCoordinator?.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)",
            collapse_body,
        )
        self.assertLess(
            collapse_body.index("if notchDropdownCoordinator == nil {"),
            collapse_body.index("setupNotchDropdown()"),
        )
        self.assertLess(
            collapse_body.index("setupNotchDropdown()"),
            collapse_body.index(
                "notchDropdownCoordinator?.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)"
            ),
        )

    def test_expand_path_nils_coordinator_so_next_collapse_must_recreate_it(self) -> None:
        expand_match = re.search(
            r"private func expandMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        collapse_match = re.search(
            r"private func collapseMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(expand_match)
        self.assertIsNotNone(collapse_match)

        expand_body = expand_match.group("body")
        collapse_body = collapse_match.group("body")

        self.assertIn("notchDropdownCoordinator?.stop()", expand_body)
        self.assertIn("notchDropdownCoordinator = nil", expand_body)
        self.assertLess(
            expand_body.index("notchDropdownCoordinator?.stop()"),
            expand_body.index("notchDropdownCoordinator = nil"),
        )
        self.assertIn("if notchDropdownCoordinator == nil {", collapse_body)
        self.assertIn("setupNotchDropdown()", collapse_body)

    def test_activation_path_nils_coordinator_so_next_collapse_must_recreate_it(self) -> None:
        activation_match = re.search(
            r"func activateHiddenItem\(_ info: HiddenItemInfo\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        collapse_match = re.search(
            r"private func collapseMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(activation_match)
        self.assertIsNotNone(collapse_match)

        activation_body = activation_match.group("body")
        collapse_body = collapse_match.group("body")

        self.assertIn("notchDropdownCoordinator?.stop()", activation_body)
        self.assertIn("notchDropdownCoordinator = nil", activation_body)
        self.assertLess(
            activation_body.index("notchDropdownCoordinator?.stop()"),
            activation_body.index("notchDropdownCoordinator = nil"),
        )
        self.assertIn("if notchDropdownCoordinator == nil {", collapse_body)
        self.assertIn("setupNotchDropdown()", collapse_body)

    def test_repeated_expand_collapse_cycles_keep_single_recreate_hook(self) -> None:
        collapse_match = re.search(
            r"private func collapseMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(collapse_match)
        collapse_body = collapse_match.group("body")

        self.assertEqual(collapse_body.count("if notchDropdownCoordinator == nil {"), 1)
        self.assertEqual(collapse_body.count("setupNotchDropdown()"), 1)
        self.assertEqual(
            collapse_body.count(
                "notchDropdownCoordinator?.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)"
            ),
            1,
        )

    def test_collapse_recreation_relies_on_setup_notch_dropdown_guards_instead_of_duplicate_checks(self) -> None:
        collapse_match = re.search(
            r"private func collapseMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(collapse_match)
        recreate_window = re.search(
            r"if notchDropdownCoordinator == nil \{\s*setupNotchDropdown\(\)\s*\}(?P<section>.*?)"
            r"notchDropdownCoordinator\?\.update",
            collapse_match.group("body"),
            re.DOTALL,
        )
        self.assertIsNotNone(recreate_window)
        recreate_section = recreate_window.group("section")

        self.assertNotIn("preferences.isPocketEnabled", recreate_section)
        self.assertNotIn("hasNotch", recreate_section)
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

    def test_pocket_toggle_off_tears_down_coordinator_and_blocks_recreation_on_collapse(self) -> None:
        preferences_match = re.search(
            r"private func handlePreferencesChanged\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        setup_match = re.search(
            r"private func setupNotchDropdown\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(preferences_match)
        self.assertIsNotNone(setup_match)

        preferences_body = preferences_match.group("body")
        setup_body = setup_match.group("body")

        self.assertIn("// Re-evaluate pocket state when toggled", preferences_body)
        self.assertIn("setupNotchDropdown()", preferences_body)
        self.assertIn("guard hasNotch, preferences.isPocketEnabled else {", setup_body)
        self.assertIn("notchDropdownCoordinator?.stop()", setup_body)
        self.assertIn("notchDropdownCoordinator = nil", setup_body)
        self.assertLess(
            setup_body.index("guard hasNotch, preferences.isPocketEnabled else {"),
            setup_body.index("notchDropdownCoordinator?.stop()"),
        )

    def test_pocket_toggle_on_then_collapse_can_create_fresh_coordinator(self) -> None:
        setup_match = re.search(
            r"private func setupNotchDropdown\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        collapse_match = re.search(
            r"private func collapseMenuBar\(\) \{(?P<body>.*?)\n    \}",
            self.status_bar_text,
            re.DOTALL,
        )
        self.assertIsNotNone(setup_match)
        self.assertIsNotNone(collapse_match)

        setup_body = setup_match.group("body")
        collapse_body = collapse_match.group("body")

        self.assertIn("let coordinator = NotchDropdownCoordinator()", setup_body)
        self.assertIn("coordinator.onItemActivated = { [weak self] info in", setup_body)
        self.assertIn("self?.activateHiddenItem(info)", setup_body)
        self.assertIn("notchDropdownCoordinator = coordinator", setup_body)
        self.assertIn("coordinator.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)", setup_body)
        self.assertIn("if notchDropdownCoordinator == nil {", collapse_body)
        self.assertIn("setupNotchDropdown()", collapse_body)
        self.assertIn(
            "notchDropdownCoordinator?.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)",
            collapse_body,
        )


if __name__ == "__main__":
    unittest.main()
