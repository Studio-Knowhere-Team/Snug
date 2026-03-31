import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
NOTCH_DROPDOWN_PANEL = REPO_ROOT / "Snug" / "StatusBar" / "NotchDropdownPanel.swift"


class NotchDropdownPanelAnimationIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.panel_text = NOTCH_DROPDOWN_PANEL.read_text(encoding="utf-8")

    def test_show_animation_uses_calayer_mask_reveal_from_zero_to_full_height(self) -> None:
        self.assertIn("private let showAnimationDuration: TimeInterval = 0.25", self.panel_text)
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"let maskLayer = CALayer\(\)\s*"
                r"maskLayer\.backgroundColor = NSColor\.black\.cgColor\s*"
                r"maskLayer\.anchorPoint = CGPoint\(x: 0\.5, y: 1\).*?"
                r"maskLayer\.bounds = CGRect\(x: 0, y: 0, width: targetFrame\.width, height: 0\)",
                re.MULTILINE | re.DOTALL,
            ),
        )
        self.assertRegex(
            self.panel_text,
            re.compile(
                r'let anim = CABasicAnimation\(keyPath: "bounds\.size\.height"\)\s*'
                r"anim\.fromValue = 0\s*"
                r"anim\.toValue = fullContentHeight\s*"
                r"anim\.duration = showAnimationDuration\s*"
                r"anim\.timingFunction = CAMediaTimingFunction\(name: \.easeOut\)",
                re.MULTILINE,
            ),
        )

    def test_hide_animation_uses_calayer_mask_collapse_from_full_to_zero(self) -> None:
        self.assertIn("private let hideAnimationDuration: TimeInterval = 0.18", self.panel_text)
        self.assertRegex(
            self.panel_text,
            re.compile(
                r'let anim = CABasicAnimation\(keyPath: "bounds\.size\.height"\)\s*'
                r"anim\.fromValue = fullContentHeight\s*"
                r"anim\.toValue = 0\s*"
                r"anim\.duration = hideAnimationDuration\s*"
                r"anim\.timingFunction = CAMediaTimingFunction\(name: \.easeIn\)",
                re.MULTILINE,
            ),
        )

    def test_hide_completion_orders_panel_out_only_after_animation_completion(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"CATransaction\.setCompletionBlock \{ \[weak self\] in\s*"
                r"guard let self, self\.animationToken == token else \{ return \}\s*"
                r"self\.completeHide\(\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"private func completeHide\(\) \{\s*"
                r"panel\.contentView\?\.layer\?\.mask = nil\s*"
                r"panel\.orderOut\(nil\)\s*"
                r"panelState = \.hidden",
                re.MULTILINE,
            ),
        )

    def test_reduce_motion_path_skips_animations_and_updates_final_visual_state_immediately(self) -> None:
        self.assertIn("private var shouldAnimateTransitions: Bool {", self.panel_text)
        self.assertIn("!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", self.panel_text)
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"if !shouldAnimateTransitions \{\s*"
                r"// No animation — show fully\s*"
                r"panel\.contentView\?\.layer\?\.mask = nil\s*"
                r"panel\.orderFront\(nil\)\s*"
                r"panelState = \.visible",
                re.MULTILINE,
            ),
        )
        self.assertIn("if !animated || !shouldAnimateTransitions {", self.panel_text)
        self.assertIn("completeHide()", self.panel_text)

    def test_show_uses_catransaction_completion_to_transition_to_visible_state(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"CATransaction\.begin\(\)\s*"
                r"CATransaction\.setCompletionBlock \{ \[weak self\] in\s*"
                r"guard let self, self\.animationToken == token else \{ return \}\s*"
                r"self\.panel\.contentView\?\.layer\?\.mask = nil\s*"
                r"self\.panelState = \.visible",
                re.MULTILINE,
            ),
        )

    def test_animation_token_prevents_overlapping_completions(self) -> None:
        self.assertIn("private var animationToken = UUID()", self.panel_text)
        self.assertEqual(
            self.panel_text.count("guard let self, self.animationToken == token else { return }"),
            2,
        )

    def test_animation_avoids_frame_height_changes_during_transition(self) -> None:
        self.assertIn("panel.setFrame(targetFrame, display: false)", self.panel_text)
        self.assertNotIn("panel.animator().setFrame", self.panel_text)
        self.assertNotIn("panel.animator().frame", self.panel_text)
        self.assertNotIn("panel.animator().setContentSize", self.panel_text)
        self.assertNotIn("panel.contentView?.animator()", self.panel_text)


if __name__ == "__main__":
    unittest.main()
