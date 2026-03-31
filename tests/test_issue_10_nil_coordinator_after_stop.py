import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
STATUS_BAR_CONTROLLER = REPO_ROOT / "Snug" / "StatusBar" / "StatusBarController.swift"


class NilCoordinatorAfterStopIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.status_bar_text = STATUS_BAR_CONTROLLER.read_text(encoding="utf-8")
        cls.status_bar_lines = cls.status_bar_text.splitlines()

    def test_expand_menu_bar_clears_coordinator_immediately_after_stop(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"private func expandMenuBar\(\) \{.*?"
                r"notchDropdownCoordinator\?\.stop\(\)\s*"
                r"notchDropdownCoordinator = nil\s*"
                r"\s*// Reveal items instantly\.\s*"
                r"separatorItem\.length = NSStatusItem\.variableLength",
                re.MULTILINE | re.DOTALL,
            ),
        )

    def test_activate_hidden_item_clears_coordinator_immediately_after_stop(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"func activateHiddenItem\(_ info: HiddenItemInfo\) \{.*?"
                r"notchDropdownCoordinator\?\.stop\(\)\s*"
                r"notchDropdownCoordinator = nil\s*"
                r"\s*// After expansion settles, move the item next to the separator then press it\.\s*"
                r"DispatchQueue\.main\.asyncAfter",
                re.MULTILINE | re.DOTALL,
            ),
        )

    def test_every_notch_dropdown_stop_site_clears_reference_on_next_line(self) -> None:
        stop_lines = [
            index
            for index, line in enumerate(self.status_bar_lines)
            if "notchDropdownCoordinator?.stop()" in line
        ]

        self.assertEqual(len(stop_lines), 5)

        for index in stop_lines:
            self.assertEqual(
                self.status_bar_lines[index + 1].strip(),
                "notchDropdownCoordinator = nil",
                msg=f"Expected stop at line {index + 1} to be followed by clearing the coordinator reference",
            )

    def test_expand_then_collapse_cycle_cannot_update_a_stopped_coordinator(self) -> None:
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
        self.assertIn(
            "notchDropdownCoordinator?.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)",
            collapse_body,
        )
        self.assertLess(
            expand_body.index("notchDropdownCoordinator?.stop()"),
            expand_body.index("notchDropdownCoordinator = nil"),
        )


if __name__ == "__main__":
    unittest.main()
