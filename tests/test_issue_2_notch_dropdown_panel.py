import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
NOTCH_DROPDOWN_PANEL = REPO_ROOT / "Snug" / "StatusBar" / "NotchDropdownPanel.swift"


class NotchDropdownPanelIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.panel_text = NOTCH_DROPDOWN_PANEL.read_text(encoding="utf-8")

    def test_notch_dropdown_panel_file_declares_main_actor_final_class_and_required_api(self) -> None:
        self.assertIn("@MainActor", self.panel_text)
        self.assertIn("final class NotchDropdownPanel: NSObject {", self.panel_text)
        self.assertIn("func show(items: [HiddenItemInfo], below notchRect: CGRect) {", self.panel_text)
        self.assertIn("func hide(animated: Bool) {", self.panel_text)
        self.assertIn("var isVisible: Bool {", self.panel_text)
        self.assertIn("var panelFrame: CGRect {", self.panel_text)

    def test_panel_state_machine_declares_all_required_states_and_visibility_logic(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"enum PanelState \{\s*"
                r"case hidden\s*"
                r"case showing\s*"
                r"case visible\s*"
                r"case hiding\s*"
                r"\}",
                re.MULTILINE,
            ),
        )
        self.assertIn("panelState == .visible || panelState == .showing", self.panel_text)
        self.assertIn("private var panelState: PanelState = .hidden", self.panel_text)

    def test_panel_window_uses_required_style_mask_and_non_activating_panel_setup(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"panel = PanelWindow\(\s*"
                r"contentRect: \.zero,\s*"
                r"styleMask: \[\s*\.nonactivatingPanel,\s*\.borderless,\s*\.fullSizeContentView\s*\]",
                re.MULTILINE,
            ),
        )
        self.assertIn("panel.level = .statusBar", self.panel_text)
        self.assertIn("panel.backgroundColor = .clear", self.panel_text)
        self.assertIn("panel.hasShadow = false", self.panel_text)
        self.assertIn("panel.hidesOnDeactivate = false", self.panel_text)
        self.assertIn("panel.isFloatingPanel = true", self.panel_text)
        self.assertIn(
            "panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]",
            self.panel_text,
        )

    def test_panel_window_overrides_focus_behavior(self) -> None:
        self.assertIn("private final class PanelWindow: NSPanel {", self.panel_text)
        self.assertIn("override var canBecomeKey: Bool { true }", self.panel_text)
        self.assertIn("override var canBecomeMain: Bool { false }", self.panel_text)

    def test_visual_effect_view_uses_native_menu_material_configuration(self) -> None:
        self.assertIn("private let visualEffectView = NSVisualEffectView()", self.panel_text)
        self.assertIn("visualEffectView.material = .dark", self.panel_text)
        self.assertIn("visualEffectView.blendingMode = .behindWindow", self.panel_text)
        self.assertIn("visualEffectView.state = .active", self.panel_text)
        self.assertIn("hostView.addSubview(containerView)", self.panel_text)
        self.assertIn("panel.contentView = hostView", self.panel_text)

    def test_all_corner_rounding(self) -> None:
        self.assertIn("private let cornerRadius: CGFloat = 12", self.panel_text)
        self.assertIn("visualEffectView.layer?.cornerRadius = cornerRadius", self.panel_text)
        self.assertIn("visualEffectView.layer?.masksToBounds = true", self.panel_text)
        # All corners rounded — no maskedCorners restriction
        self.assertNotIn("maskedCorners", self.panel_text)

    def test_grid_layout_uses_stack_views_cell_size_and_spacing_constants(self) -> None:
        self.assertIn('private let cellSize = NSSize(width: 32, height: 32)', self.panel_text)
        self.assertIn("private let gridSpacing: CGFloat = 8", self.panel_text)
        self.assertIn("private let verticalStackView = NSStackView()", self.panel_text)
        self.assertIn("verticalStackView.orientation = .vertical", self.panel_text)
        self.assertIn("verticalStackView.spacing = gridSpacing", self.panel_text)
        self.assertIn("let rowStackView = NSStackView()", self.panel_text)
        self.assertIn("rowStackView.orientation = .horizontal", self.panel_text)
        self.assertIn("rowStackView.spacing = gridSpacing", self.panel_text)

    def test_icon_buttons_are_borderless_use_scaled_icons_and_show_tooltips(self) -> None:
        self.assertIn('private let iconSize = NSSize(width: 24, height: 24)', self.panel_text)
        self.assertIn("button.isBordered = false", self.panel_text)
        self.assertIn("button.imagePosition = .imageOnly", self.panel_text)
        self.assertIn("button.imageScaling = .scaleNone", self.panel_text)
        self.assertIn("button.toolTip = item.name", self.panel_text)
        self.assertIn("if let icon = item.icon?.scaled(to: iconSize) {", self.panel_text)
        self.assertIn("button.image = icon", self.panel_text)

    def test_hover_button_uses_white_alpha_highlight_with_hover_enabled_gating(self) -> None:
        self.assertIn("button.hoverColor = NSColor.white.withAlphaComponent(0.1)", self.panel_text)
        self.assertIn("var hoverEnabled: Bool = false", self.panel_text)
        self.assertIn("override func mouseEntered(with event: NSEvent) {", self.panel_text)
        self.assertIn("override func mouseExited(with event: NSEvent) {", self.panel_text)
        self.assertIn("guard hoverEnabled else { return }", self.panel_text)
        self.assertIn("backgroundView.layer?.backgroundColor = hoverColor.cgColor", self.panel_text)
        self.assertIn("backgroundView.layer?.backgroundColor = NSColor.clear.cgColor", self.panel_text)

    def test_scroll_view_caps_height_and_enables_scrolling_for_more_than_three_rows(self) -> None:
        self.assertIn("private let maxVisibleRows = 3", self.panel_text)
        self.assertIn("private let maxScrollHeight: CGFloat = 160", self.panel_text)
        self.assertIn("private let scrollView = NSScrollView()", self.panel_text)
        self.assertIn("scrollView.hasVerticalScroller = true", self.panel_text)
        self.assertIn("scrollView.autohidesScrollers = true", self.panel_text)
        self.assertIn("let height = min(fittingSize.height, maxScrollHeight)", self.panel_text)
        self.assertIn(
            "scrollView.hasVerticalScroller = fittingSize.height > maxScrollHeight || rowCount() > maxVisibleRows",
            self.panel_text,
        )

    def test_frame_calculation_uses_notch_origin_and_width(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"targetFrame = CGRect\(\s*"
                r"x: notchRect\.origin\.x,\s*"
                r"y: round\(notchRect\.minY - size\.height\),\s*"
                r"width: notchWidth,\s*"
                r"height: size\.height\s*"
                r"\)",
                re.MULTILINE,
            ),
        )

    def test_show_rebuilds_grid_sets_target_frame_and_orders_panel_front(self) -> None:
        self.assertIn("guard !items.isEmpty else {", self.panel_text)
        self.assertIn("hide(animated: false)", self.panel_text)
        self.assertIn("rebuildGrid(items: items, notchRect: notchRect)", self.panel_text)
        self.assertIn("panel.setFrame(targetFrame, display: false)", self.panel_text)
        self.assertIn("panel.orderFront(nil)", self.panel_text)

    def test_animation_uses_tokens_and_mask_based_reveal(self) -> None:
        self.assertIn("private var animationToken = UUID()", self.panel_text)
        self.assertIn("guard let self, self.animationToken == token else { return }", self.panel_text)
        self.assertIn("private var filterRemovalToken = UUID()", self.panel_text)
        self.assertIn("deinit {", self.panel_text)
        self.assertIn("panel.contentView?.layer?.mask = maskLayer", self.panel_text)
        self.assertIn('CABasicAnimation(keyPath: "bounds.size.height")', self.panel_text)

    def test_show_and_hide_animate_between_required_panel_states(self) -> None:
        self.assertIn("panelState = .showing", self.panel_text)
        self.assertIn("panelState = .hiding", self.panel_text)
        self.assertIn("self.panelState = .visible", self.panel_text)
        self.assertIn("panelState = .hidden", self.panel_text)
        self.assertIn("panel.orderOut(nil)", self.panel_text)

    def test_issue_3_uses_calayer_mask_animation_and_reduce_motion_support(self) -> None:
        self.assertIn("private let showAnimationDuration: TimeInterval = 0.25", self.panel_text)
        self.assertIn("private let hideAnimationDuration: TimeInterval = 0.18", self.panel_text)
        self.assertIn("CAMediaTimingFunction(name: .easeOut)", self.panel_text)
        self.assertIn("CAMediaTimingFunction(name: .easeIn)", self.panel_text)
        self.assertIn("anim.fromValue = 0", self.panel_text)
        self.assertIn("anim.toValue = fullContentHeight", self.panel_text)
        self.assertIn("anim.fromValue = fullContentHeight", self.panel_text)
        self.assertIn("anim.toValue = 0", self.panel_text)
        self.assertIn("!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", self.panel_text)
        self.assertIn("if !animated || !shouldAnimateTransitions {", self.panel_text)


if __name__ == "__main__":
    unittest.main()
