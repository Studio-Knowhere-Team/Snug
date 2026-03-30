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
        self.assertIn("panel.hasShadow = true", self.panel_text)
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
        self.assertIn("visualEffectView.material = .menu", self.panel_text)
        self.assertIn("visualEffectView.blendingMode = .behindWindow", self.panel_text)
        self.assertIn("visualEffectView.state = .active", self.panel_text)
        self.assertIn("panel.contentView = visualEffectView", self.panel_text)

    def test_bottom_only_rounding_uses_mask_image_and_cap_insets(self) -> None:
        self.assertIn("private let cornerRadius: CGFloat = 12", self.panel_text)
        self.assertIn("private func applyMaskImage() {", self.panel_text)
        self.assertIn("visualEffectView.maskImage = image", self.panel_text)
        self.assertIn(
            "image.capInsets = NSEdgeInsets(top: size.height - 1, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)",
            self.panel_text,
        )
        self.assertIn("image.resizingMode = .stretch", self.panel_text)

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

    def test_hover_button_uses_quaternary_label_highlight(self) -> None:
        self.assertIn("button.hoverColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2)", self.panel_text)
        self.assertIn("override func mouseEntered(with event: NSEvent) {", self.panel_text)
        self.assertIn("override func mouseExited(with event: NSEvent) {", self.panel_text)
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

    def test_frame_calculation_centers_panel_below_notch_with_zero_gap(self) -> None:
        self.assertRegex(
            self.panel_text,
            re.compile(
                r"private func frame\(forContentSize size: NSSize, below notchRect: CGRect\) -> CGRect \{\s*"
                r"let width = size\.width\s*"
                r"let height = size\.height\s*"
                r"return CGRect\(\s*"
                r"x: round\(notchRect\.midX - \(width / 2\)\),\s*"
                r"y: round\(notchRect\.minY - height\),\s*"
                r"width: width,\s*"
                r"height: height",
                re.MULTILINE,
            ),
        )

    def test_show_rebuilds_grid_sets_target_frame_and_orders_panel_front(self) -> None:
        self.assertIn("guard !items.isEmpty else {", self.panel_text)
        self.assertIn("hide(animated: false)", self.panel_text)
        self.assertIn("rebuildGrid(items: items, notchRect: notchRect)", self.panel_text)
        self.assertIn("let targetFrame = frame(forContentSize: contentSize(), below: notchRect)", self.panel_text)
        self.assertIn("panel.setContentSize(targetFrame.size)", self.panel_text)
        self.assertIn("panel.setFrame(targetFrame, display: false)", self.panel_text)
        self.assertIn("panel.orderFront(nil)", self.panel_text)

    def test_animation_interruption_uses_presentation_layer_and_tokens_to_prevent_overlap(self) -> None:
        self.assertIn("private var animationToken = UUID()", self.panel_text)
        self.assertIn("let token = prepareForAnimation()", self.panel_text)
        self.assertIn("let startingTranslationY = currentTranslationY(from: visualEffectView.layer?.presentation())", self.panel_text)
        self.assertIn("let startingOpacity = currentOpacity(from: visualEffectView.layer?.presentation())", self.panel_text)
        self.assertIn("guard let self, self.animationToken == token else { return }", self.panel_text)
        self.assertIn("private func syncVisualStateFromPresentationLayer() {", self.panel_text)
        self.assertIn("layer.opacity = presentation.opacity", self.panel_text)
        self.assertIn("layer.transform = presentation.transform", self.panel_text)
        self.assertIn("visualEffectView.layer?.removeAllAnimations()", self.panel_text)

    def test_show_and_hide_animate_between_required_panel_states(self) -> None:
        self.assertIn("private func animateShow(", self.panel_text)
        self.assertIn("private func animateHide(", self.panel_text)
        self.assertIn("panelState = .showing", self.panel_text)
        self.assertIn("panelState = .hiding", self.panel_text)
        self.assertIn("self.panelState = .visible", self.panel_text)
        self.assertIn("panelState = .hidden", self.panel_text)
        self.assertIn("panel.orderOut(nil)", self.panel_text)

    def test_issue_3_uses_required_animation_context_translate_and_reduce_motion_support(self) -> None:
        self.assertIn("private let showAnimationDuration: TimeInterval = 0.2", self.panel_text)
        self.assertIn("private let hideAnimationDuration: TimeInterval = 0.15", self.panel_text)
        self.assertIn("private let hiddenYOffset: CGFloat = -4", self.panel_text)
        self.assertIn("NSAnimationContext.runAnimationGroup { context in", self.panel_text)
        self.assertIn("context.timingFunction = CAMediaTimingFunction(name: .easeOut)", self.panel_text)
        self.assertIn("context.timingFunction = CAMediaTimingFunction(name: .easeIn)", self.panel_text)
        self.assertIn("visualEffectView.animator().alphaValue = 1", self.panel_text)
        self.assertIn("visualEffectView.animator().alphaValue = 0", self.panel_text)
        self.assertIn("visualEffectView.layer?.animator().transform = CATransform3DIdentity", self.panel_text)
        self.assertIn("visualEffectView.layer?.animator().transform = hiddenTransform", self.panel_text)
        self.assertIn("!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", self.panel_text)
        self.assertIn("if !animated || !shouldAnimateTransitions {", self.panel_text)


if __name__ == "__main__":
    unittest.main()
