import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
NOTCH_DROPDOWN_PANEL = REPO_ROOT / "Snug" / "StatusBar" / "NotchDropdownPanel.swift"


class NotchDropdownPanelAnimationIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.panel_text = NOTCH_DROPDOWN_PANEL.read_text(encoding="utf-8")

    def test_show_animation_uses_required_duration_timing_alpha_and_translate(self) -> None:
        self.assertIn("private let showAnimationDuration: TimeInterval = 0.2", self.panel_text)
        self.assertIn("private let hiddenYOffset: CGFloat = -4", self.panel_text)
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"private func animateShow\(\s*"
                r"token: UUID,\s*"
                r"fromOpacity: Float,\s*"
                r"fromTranslationY: CGFloat\s*"
                r"\) \{\s*"
                r"panelState = \.showing\s*"
                r"visualEffectView\.alphaValue = CGFloat\(fromOpacity\)\s*"
                r"visualEffectView\.layer\?\.transform = translationTransform\(y: fromTranslationY\)\s*"
                r"NSAnimationContext\.runAnimationGroup \{ context in\s*"
                r"context\.duration = showAnimationDuration\s*"
                r"context\.timingFunction = CAMediaTimingFunction\(name: \.easeOut\)\s*"
                r"visualEffectView\.animator\(\)\.alphaValue = 1\s*"
                r"visualEffectView\.layer\?\.animator\(\)\.transform = CATransform3DIdentity",
                re.MULTILINE,
            ),
        )

    def test_hide_animation_uses_required_duration_timing_reverse_alpha_and_translate(self) -> None:
        self.assertIn("private let hideAnimationDuration: TimeInterval = 0.15", self.panel_text)
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"private func animateHide\(\s*"
                r"token: UUID,\s*"
                r"fromOpacity: Float,\s*"
                r"fromTranslationY: CGFloat\s*"
                r"\) \{\s*"
                r"panelState = \.hiding\s*"
                r"visualEffectView\.alphaValue = CGFloat\(fromOpacity\)\s*"
                r"visualEffectView\.layer\?\.transform = translationTransform\(y: fromTranslationY\)\s*"
                r"NSAnimationContext\.runAnimationGroup \{ context in\s*"
                r"context\.duration = hideAnimationDuration\s*"
                r"context\.timingFunction = CAMediaTimingFunction\(name: \.easeIn\)\s*"
                r"visualEffectView\.animator\(\)\.alphaValue = 0\s*"
                r"visualEffectView\.layer\?\.animator\(\)\.transform = hiddenTransform",
                re.MULTILINE,
            ),
        )

    def test_hide_completion_orders_panel_out_only_after_animation_completion(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"private func animateHide\([\s\S]*?"
                r"completionHandler: \{ \[weak self\] in\s*"
                r"guard let self, self\.animationToken == token else \{ return \}\s*"
                r"self\.completeHide\(\)\s*"
                r"\}",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"private func completeHide\(\) \{\s*"
                r"panel\.orderOut\(nil\)\s*"
                r"panelState = \.hidden\s*"
                r"visualEffectView\.alphaValue = 0\s*"
                r"visualEffectView\.layer\?\.transform = hiddenTransform",
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
                r"panelState = \.visible\s*"
                r"visualEffectView\.alphaValue = 1\s*"
                r"visualEffectView\.layer\?\.transform = CATransform3DIdentity",
                re.MULTILINE,
            ),
        )
        self.assertIn("if !animated || !shouldAnimateTransitions {", self.panel_text)
        self.assertIn("completeHide()", self.panel_text)

    def test_show_and_hide_resume_from_presentation_layer_to_avoid_visual_jank(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"let token = prepareForAnimation\(\)\s*"
                r"let startingTranslationY = currentTranslationY\(from: visualEffectView\.layer\?\.presentation\(\)\) \?\? currentTranslationY\(from: visualEffectView\.layer\) \?\? hiddenYOffset\s*"
                r"let startingOpacity = currentOpacity\(from: visualEffectView\.layer\?\.presentation\(\)\) \?\? currentOpacity\(from: visualEffectView\.layer\) \?\? 0",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"let token = prepareForAnimation\(\)\s*"
                r"let startingOpacity = currentOpacity\(from: visualEffectView\.layer\?\.presentation\(\)\) \?\? currentOpacity\(from: visualEffectView\.layer\) \?\? 1\s*"
                r"let startingTranslationY = currentTranslationY\(from: visualEffectView\.layer\?\.presentation\(\)\) \?\? currentTranslationY\(from: visualEffectView\.layer\) \?\? 0",
                re.MULTILINE,
            ),
        )

    def test_animation_token_and_presentation_sync_cancel_overlapping_completions(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"private func prepareForAnimation\(\) -> UUID \{\s*"
                r"let token = UUID\(\)\s*"
                r"animationToken = token\s*"
                r"syncVisualStateFromPresentationLayer\(\)\s*"
                r"visualEffectView\.layer\?\.removeAllAnimations\(\)\s*"
                r"return token",
                re.MULTILINE,
            ),
        )
        self.assertEqual(
            self.panel_text.count("guard let self, self.animationToken == token else { return }"),
            2,
        )

    def test_animation_avoids_frame_height_changes_during_transition(self) -> None:
        self.assertIn("panel.setContentSize(targetFrame.size)", self.panel_text)
        self.assertIn("panel.setFrame(targetFrame, display: false)", self.panel_text)
        self.assertNotIn("panel.animator().setFrame", self.panel_text)
        self.assertNotIn("panel.animator().frame", self.panel_text)
        self.assertNotIn("panel.animator().setContentSize", self.panel_text)
        self.assertNotIn("panel.contentView?.animator()", self.panel_text)


if __name__ == "__main__":
    unittest.main()
