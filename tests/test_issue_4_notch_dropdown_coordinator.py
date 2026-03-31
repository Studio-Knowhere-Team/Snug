import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
COORDINATOR = REPO_ROOT / "Snug" / "StatusBar" / "NotchDropdownCoordinator.swift"


class NotchDropdownCoordinatorIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.coordinator_text = COORDINATOR.read_text(encoding="utf-8")

    def test_coordinator_declares_main_actor_api_state_and_safety_net(self) -> None:
        self.assertIn("@MainActor", self.coordinator_text)
        self.assertIn("final class NotchDropdownCoordinator {", self.coordinator_text)
        self.assertIn("var onItemActivated: ((HiddenItemInfo) -> Void)?", self.coordinator_text)
        self.assertIn("private let panel = NotchDropdownPanel()", self.coordinator_text)
        self.assertIn("private var trackingWindow: TrackingWindow?", self.coordinator_text)
        self.assertIn("private var dwellToken: UUID?", self.coordinator_text)
        self.assertIn("private var graceToken: UUID?", self.coordinator_text)
        self.assertIn("private var globalMouseMonitor: Any?", self.coordinator_text)
        self.assertIn("private var localEventMonitor: Any?", self.coordinator_text)
        self.assertIn("func stop() {", self.coordinator_text)
        self.assertIn("deinit {", self.coordinator_text)
        self.assertIn("MainActor.assumeIsolated {", self.coordinator_text)
        self.assertIn("stop()", self.coordinator_text)

    def test_update_tracks_items_and_notch_rect_handles_empty_notch_and_refreshes_visible_panel(self) -> None:
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"func update\(items: \[HiddenItemInfo\], notchRect: CGRect\) \{\s*"
                r"hiddenItems = items\s*"
                r"self\.notchRect = notchRect",
                re.MULTILINE,
            ),
        )
        self.assertIn('snugLog(" NotchDropdownCoordinator.update: items=%d notch=(%.0f, %.0f, %.0f, %.0f)"', self.coordinator_text)
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"if notchRect\.isEmpty \{\s*"
                r"removeTrackingWindow\(\)\s*"
                r"dismissPanel\(animated: false, reason: \"emptyNotchRect\"\)\s*"
                r"return",
                re.MULTILINE,
            ),
        )
        self.assertIn("installTrackingWindow()", self.coordinator_text)
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"if panel\.isVisible \{\s*"
                r"panel\.show\(items: hiddenItems, below: notchRect\)\s*"
                r"\}",
                re.MULTILINE,
            ),
        )

    def test_phase1_tracking_window_uses_invisible_borderless_window_and_tracking_area_callbacks(self) -> None:
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"let window = TrackingWindow\(\s*"
                r"contentRect: notchRect,\s*"
                r"styleMask: \[\.borderless\],\s*"
                r"backing: \.buffered,\s*"
                r"defer: false",
                re.MULTILINE,
            ),
        )
        self.assertIn("window.level = .statusBar", self.coordinator_text)
        self.assertIn("window.backgroundColor = .clear", self.coordinator_text)
        self.assertIn("window.isOpaque = false", self.coordinator_text)
        self.assertIn("window.hasShadow = false", self.coordinator_text)
        self.assertIn("window.ignoresMouseEvents = false", self.coordinator_text)
        self.assertIn(
            "window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]",
            self.coordinator_text,
        )
        self.assertIn("trackingView.onMouseEntered = { [weak self] in", self.coordinator_text)
        self.assertIn("self?.handleTrackingMouseEntered()", self.coordinator_text)
        self.assertIn("trackingView.onMouseExited = { [weak self] in", self.coordinator_text)
        self.assertIn("self?.handleTrackingMouseExited()", self.coordinator_text)
        self.assertIn('snugLog(" NotchDropdownCoordinator: phase1 tracking window installed")', self.coordinator_text)
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"let trackingArea = NSTrackingArea\(\s*"
                r"rect: bounds,\s*"
                r"options: \[\.activeAlways, \.mouseEnteredAndExited\],\s*"
                r"owner: self,\s*"
                r"userInfo: nil",
                re.MULTILINE,
            ),
        )
        self.assertIn("override func mouseEntered(with event: NSEvent) {", self.coordinator_text)
        self.assertIn("override func mouseExited(with event: NSEvent) {", self.coordinator_text)

    def test_mouse_enter_and_exit_implement_dwell_timer_with_uuid_token_cancellation(self) -> None:
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func handleTrackingMouseEntered\(\) \{\s*"
                r"cursorIsInTrackingZone = true\s*"
                r"snugLog\(\" NotchDropdownCoordinator: tracking mouseEntered\"\)\s*"
                r"if panel\.isVisible \{\s*"
                r"updateCursorZoneState\(\)\s*"
                r"return\s*"
                r"\}\s*"
                r"startDwellTimer\(\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func handleTrackingMouseExited\(\) \{\s*"
                r"cursorIsInTrackingZone = false\s*"
                r"snugLog\(\" NotchDropdownCoordinator: tracking mouseExited\"\)\s*"
                r"if panel\.isVisible \{\s*"
                r"updateCursorZoneState\(\)\s*"
                r"return\s*"
                r"\}\s*"
                r"cancelDwellTimer\(\)",
                re.MULTILINE,
            ),
        )
        self.assertIn("private let dwellDelay: TimeInterval = 0.3", self.coordinator_text)
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func startDwellTimer\(\) \{\s*"
                r"let token = UUID\(\)\s*"
                r"dwellToken = token\s*"
                r"snugLog\(\" NotchDropdownCoordinator: dwell scheduled\"\)\s*"
                r"DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ dwellDelay\) \{ \[weak self\] in\s*"
                r"guard let self, self\.dwellToken == token else \{ return \}\s*"
                r"self\.dwellToken = nil\s*"
                r"snugLog\(\" NotchDropdownCoordinator: dwell completed\"\)\s*"
                r"self\.showPanel\(\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func cancelDwellTimer\(\) \{\s*"
                r"guard dwellToken != nil else \{ return \}\s*"
                r"dwellToken = nil\s*"
                r"snugLog\(\" NotchDropdownCoordinator: dwell cancelled\"\)",
                re.MULTILINE,
            ),
        )

    def test_phase2_show_guards_install_monitors_and_support_escape_dismissal(self) -> None:
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func showPanel\(\) \{\s*"
                r"guard !hiddenItems\.isEmpty else \{\s*"
                r"snugLog\(\" NotchDropdownCoordinator: show skipped, no hidden items\"\)\s*"
                r"return\s*"
                r"\}\s*"
                r"guard !notchRect\.isEmpty else \{\s*"
                r"snugLog\(\" NotchDropdownCoordinator: show skipped, no notch rect\"\)\s*"
                r"return\s*"
                r"\}\s*"
                r"panel\.show\(items: hiddenItems, below: notchRect\)",
                re.MULTILINE,
            ),
        )
        self.assertIn("cursorIsInTrackingZone = isMouseInTrackingZone()", self.coordinator_text)
        self.assertIn("cursorIsInPanelZone = isMouseInPanelZone()", self.coordinator_text)
        self.assertIn("cursorIsInZone = cursorIsInTrackingZone || cursorIsInPanelZone", self.coordinator_text)
        self.assertIn("installActiveMonitors()", self.coordinator_text)
        self.assertIn("cancelGraceHide()", self.coordinator_text)
        self.assertIn('snugLog(" NotchDropdownCoordinator: phase2 active")', self.coordinator_text)
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"globalMouseMonitor = NSEvent\.addGlobalMonitorForEvents\(matching: \.mouseMoved\) \{ \[weak self\] _ in\s*"
                r"DispatchQueue\.main\.async \{ \[weak self\] in\s*"
                r"self\?\.handleMouseActivity\(\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"localEventMonitor = NSEvent\.addLocalMonitorForEvents\(matching: \[\.(?:mouseMoved|keyDown), \.(?:mouseMoved|keyDown)\]\) \{ \[weak self\] event -> NSEvent\? in",
                re.MULTILINE,
            ),
        )
        self.assertIn("let eventType = event.type", self.coordinator_text)
        self.assertIn("if eventType == .keyDown, event.keyCode == 53 {", self.coordinator_text)
        self.assertIn('snugLog(" NotchDropdownCoordinator: escape pressed")', self.coordinator_text)
        self.assertIn('self.dismissPanel(animated: true, reason: "escape")', self.coordinator_text)
        self.assertIn("return nil", self.coordinator_text)
        self.assertIn("if eventType == .mouseMoved {", self.coordinator_text)
        self.assertIn("self?.handleMouseActivity()", self.coordinator_text)

    def test_edge_detection_and_grace_timer_only_fire_on_zone_transitions(self) -> None:
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func handleMouseActivity\(\) \{\s*"
                r"guard panel\.isVisible else \{ return \}\s*"
                r"cursorIsInTrackingZone = isMouseInTrackingZone\(\)\s*"
                r"cursorIsInPanelZone = isMouseInPanelZone\(\)\s*"
                r"updateCursorZoneState\(\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func updateCursorZoneState\(\) \{\s*"
                r"let isInZoneNow = cursorIsInTrackingZone \|\| cursorIsInPanelZone\s*"
                r"guard isInZoneNow != cursorIsInZone else \{ return \}\s*"
                r"cursorIsInZone = isInZoneNow\s*"
                r"if cursorIsInZone \{\s*"
                r"snugLog\(\" NotchDropdownCoordinator: cursor entered active zone\"\)\s*"
                r"cancelGraceHide\(\)\s*"
                r"\} else \{\s*"
                r"snugLog\(\" NotchDropdownCoordinator: cursor exited active zone\"\)\s*"
                r"scheduleGraceHide\(\)",
                re.MULTILINE,
            ),
        )
        self.assertIn("private let graceDelay: TimeInterval = 0.2", self.coordinator_text)
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func scheduleGraceHide\(\) \{\s*"
                r"let token = UUID\(\)\s*"
                r"graceToken = token\s*"
                r"snugLog\(\" NotchDropdownCoordinator: grace scheduled\"\)\s*"
                r"DispatchQueue\.main\.asyncAfter\(deadline: \.now\(\) \+ graceDelay\) \{ \[weak self\] in\s*"
                r"guard let self, self\.graceToken == token else \{ return \}\s*"
                r"self\.graceToken = nil",
                re.MULTILINE,
            ),
        )
        self.assertIn("guard !self.cursorIsInTrackingZone, !self.cursorIsInPanelZone else {", self.coordinator_text)
        self.assertIn("self.cursorIsInZone = true", self.coordinator_text)
        self.assertIn('snugLog(" NotchDropdownCoordinator: grace expired but cursor returned")', self.coordinator_text)
        self.assertIn('snugLog(" NotchDropdownCoordinator: grace completed")', self.coordinator_text)
        self.assertIn('self.dismissPanel(animated: true, reason: "graceTimeout")', self.coordinator_text)
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func cancelGraceHide\(\) \{\s*"
                r"guard graceToken != nil else \{ return \}\s*"
                r"graceToken = nil\s*"
                r"snugLog\(\" NotchDropdownCoordinator: grace cancelled\"\)",
                re.MULTILINE,
            ),
        )

    def test_stop_and_dismiss_cleanup_cancel_timers_remove_monitors_and_tracking_window(self) -> None:
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"func stop\(\) \{\s*"
                r"snugLog\(\" NotchDropdownCoordinator\.stop\"\)\s*"
                r"cancelDwellTimer\(\)\s*"
                r"cancelGraceHide\(\)\s*"
                r"dismissPanel\(animated: false, reason: \"stop\"\)\s*"
                r"removeTrackingWindow\(\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func dismissPanel\(animated: Bool, reason: String\) \{\s*"
                r"cancelDwellTimer\(\)\s*"
                r"cancelGraceHide\(\)\s*"
                r"removeActiveMonitors\(\)\s*"
                r"panel\.hide\(animated: animated\)\s*"
                r"cursorIsInPanelZone = false\s*"
                r"cursorIsInZone = false\s*"
                r"snugLog\(\" NotchDropdownCoordinator: panel dismissed \(%@\)\", reason\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func removeActiveMonitors\(\) \{\s*"
                r"if let globalMouseMonitor \{\s*"
                r"NSEvent\.removeMonitor\(globalMouseMonitor\)\s*"
                r"self\.globalMouseMonitor = nil\s*"
                r"\}\s*"
                r"if let localEventMonitor \{\s*"
                r"NSEvent\.removeMonitor\(localEventMonitor\)\s*"
                r"self\.localEventMonitor = nil\s*"
                r"\}\s*"
                r"snugLog\(\" NotchDropdownCoordinator: monitors removed\"\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func removeTrackingWindow\(\) \{\s*"
                r"guard let trackingWindow else \{ return \}\s*"
                r"trackingWindow\.orderOut\(nil\)\s*"
                r"self\.trackingWindow = nil\s*"
                r"cursorIsInTrackingZone = false\s*"
                r"snugLog\(\" NotchDropdownCoordinator: phase1 tracking window removed\"\)",
                re.MULTILINE,
            ),
        )

    def test_item_activation_and_hit_testing_paths_are_wired_for_panel_and_notch_regions(self) -> None:
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"init\(\) \{\s*"
                r"panel\.onItemSelected = \{ \[weak self\] item in\s*"
                r"guard let self else \{ return \}\s*"
                r"snugLog\(\" NotchDropdownCoordinator: item activated '%@'\", item\.name\)\s*"
                r"self\.dismissPanel\(animated: true, reason: \"itemActivated\"\)\s*"
                r"self\.onItemActivated\?\(item\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func isMouseInTrackingZone\(\) -> Bool \{\s*"
                r"guard let trackingWindow else \{ return false \}\s*"
                r"return trackingWindow\.frame\.contains\(NSEvent\.mouseLocation\)",
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            self.coordinator_text,
            re.compile(
                r"private func isMouseInPanelZone\(\) -> Bool \{\s*"
                r"panel\.panelFrame\.contains\(NSEvent\.mouseLocation\)",
                re.MULTILINE,
            ),
        )


if __name__ == "__main__":
    unittest.main()
