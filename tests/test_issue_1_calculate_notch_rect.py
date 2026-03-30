import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
STATUS_BAR_CONTROLLER = REPO_ROOT / "Snug" / "StatusBar" / "StatusBarController.swift"


class CalculateNotchRectIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.status_bar_text = STATUS_BAR_CONTROLLER.read_text(encoding="utf-8")

    def test_calculate_notch_rect_method_exists_with_cgrect_return_type(self) -> None:
        self.assertIn("private func calculateNotchRect() -> CGRect {", self.status_bar_text)

    def test_calculate_notch_rect_uses_existing_screen_safe_area_and_auxiliary_apis(self) -> None:
        self.assertIn("let notchHeight = screen.safeAreaInsets.top", self.status_bar_text)
        self.assertIn("let leftArea = screen.auxiliaryTopLeftArea", self.status_bar_text)
        self.assertIn("let rightArea = screen.auxiliaryTopRightArea", self.status_bar_text)

    def test_calculate_notch_rect_computes_edges_from_left_and_right_auxiliary_areas(self) -> None:
        self.assertIn("let notchMinX = screen.frame.origin.x + leftArea.maxX", self.status_bar_text)
        self.assertIn("let notchMaxX = screen.frame.origin.x + rightArea.minX", self.status_bar_text)
        self.assertIn("let notchWidth = notchMaxX - notchMinX", self.status_bar_text)

    def test_calculate_notch_rect_builds_screen_space_rect_from_notch_geometry(self) -> None:
        self.assertRegex(
            self.status_bar_text,
            re.compile(
                r"let notchRect = CGRect\(\s*"
                r"x: notchMinX,\s*"
                r"y: screen\.frame\.maxY - notchHeight,\s*"
                r"width: notchWidth,\s*"
                r"height: notchHeight\s*"
                r"\)",
                re.MULTILINE,
            ),
        )

    def test_calculate_notch_rect_returns_zero_for_non_notch_or_invalid_geometry(self) -> None:
        self.assertIn("guard notchHeight > 0,", self.status_bar_text)
        self.assertIn("guard notchWidth > 0 else {", self.status_bar_text)
        self.assertGreaterEqual(self.status_bar_text.count("return .zero"), 3)

    def test_calculate_notch_rect_logs_zero_and_non_zero_results(self) -> None:
        self.assertGreaterEqual(
            self.status_bar_text.count('snugLog(" calculateNotchRect: x=0 y=0 width=0 height=0")'),
            3,
        )
        self.assertIn('snugLog(" calculateNotchRect: x=%.0f y=%.0f width=%.0f height=%.0f"', self.status_bar_text)
        self.assertIn("notchRect.origin.x, notchRect.origin.y, notchRect.width, notchRect.height", self.status_bar_text)

    def test_calculate_safe_left_x_uses_notch_rect_and_preserves_non_notch_fallback(self) -> None:
        self.assertIn("let notchRect = calculateNotchRect()", self.status_bar_text)
        self.assertIn("hasNotch = !notchRect.isEmpty", self.status_bar_text)
        self.assertIn("safeLeftX = hasNotch ? notchRect.maxX : 80", self.status_bar_text)
        self.assertIn('snugLog(" calculateSafeLeftX: hasNotch=%d, safeLeftX=%.0f"', self.status_bar_text)


if __name__ == "__main__":
    unittest.main()
