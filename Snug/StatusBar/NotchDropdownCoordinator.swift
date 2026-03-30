import AppKit

@MainActor
final class NotchDropdownCoordinator {

    // MARK: - Callbacks

    var onItemActivated: ((HiddenItemInfo) -> Void)?

    // MARK: - State

    private let panel = NotchDropdownPanel()

    private var hiddenItems: [HiddenItemInfo] = []
    private var notchRect: CGRect = .zero
    private var trackingWindow: TrackingWindow?

    private var dwellToken: UUID?
    private var graceToken: UUID?

    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?

    private var cursorIsInTrackingZone = false
    private var cursorIsInPanelZone = false
    private var cursorIsInZone = false

    private let dwellDelay: TimeInterval = 0.3
    private let graceDelay: TimeInterval = 0.2

    // MARK: - Init

    init() {
        panel.onItemSelected = { [weak self] item in
            guard let self else { return }
            snugLog(" NotchDropdownCoordinator: item activated '%@'", item.name)
            self.dismissPanel(animated: true, reason: "itemActivated")
            self.onItemActivated?(item)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    // MARK: - Public API

    func update(items: [HiddenItemInfo], notchRect: CGRect) {
        hiddenItems = items
        self.notchRect = notchRect

        snugLog(" NotchDropdownCoordinator.update: items=%d notch=(%.0f, %.0f, %.0f, %.0f)",
              items.count, notchRect.origin.x, notchRect.origin.y, notchRect.width, notchRect.height)

        if notchRect.isEmpty {
            removeTrackingWindow()
            dismissPanel(animated: false, reason: "emptyNotchRect")
            return
        }

        installTrackingWindow()

        if panel.isVisible {
            panel.show(items: hiddenItems, below: notchRect)
        }
    }

    func updateItems(_ items: [HiddenItemInfo]) {
        hiddenItems = items

        snugLog(" NotchDropdownCoordinator.updateItems: items=%d", items.count)

        if panel.isVisible {
            if hiddenItems.isEmpty {
                dismissPanel(animated: true, reason: "emptyItems")
            } else if !notchRect.isEmpty {
                panel.show(items: hiddenItems, below: notchRect)
            }
        }
    }

    func dismissPanel() {
        dismissPanel(animated: true, reason: "externalDismiss")
    }

    func stop() {
        snugLog(" NotchDropdownCoordinator.stop")
        cancelDwellTimer()
        cancelGraceHide()
        dismissPanel(animated: false, reason: "stop")
        removeTrackingWindow()
    }

    // MARK: - Phase 1

    private func installTrackingWindow() {
        if let trackingWindow {
            if trackingWindow.frame != notchRect {
                trackingWindow.setFrame(notchRect, display: false)
            }
            trackingWindow.orderFront(nil)
            return
        }

        let trackingView = TrackingView(frame: NSRect(origin: .zero, size: notchRect.size))
        trackingView.onMouseEntered = { [weak self] in
            self?.handleTrackingMouseEntered()
        }
        trackingView.onMouseExited = { [weak self] in
            self?.handleTrackingMouseExited()
        }

        let window = TrackingWindow(
            contentRect: notchRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = trackingView
        window.orderFront(nil)

        trackingWindow = window
        snugLog(" NotchDropdownCoordinator: phase1 tracking window installed")
    }

    private func removeTrackingWindow() {
        guard let trackingWindow else { return }
        trackingWindow.orderOut(nil)
        self.trackingWindow = nil
        cursorIsInTrackingZone = false
        snugLog(" NotchDropdownCoordinator: phase1 tracking window removed")
    }

    private func handleTrackingMouseEntered() {
        cursorIsInTrackingZone = true
        snugLog(" NotchDropdownCoordinator: tracking mouseEntered")

        if panel.isVisible {
            updateCursorZoneState()
            return
        }

        startDwellTimer()
    }

    private func handleTrackingMouseExited() {
        cursorIsInTrackingZone = false
        snugLog(" NotchDropdownCoordinator: tracking mouseExited")

        if panel.isVisible {
            updateCursorZoneState()
            return
        }

        cancelDwellTimer()
    }

    private func startDwellTimer() {
        let token = UUID()
        dwellToken = token
        snugLog(" NotchDropdownCoordinator: dwell scheduled")

        DispatchQueue.main.asyncAfter(deadline: .now() + dwellDelay) { [weak self] in
            guard let self, self.dwellToken == token else { return }
            self.dwellToken = nil
            snugLog(" NotchDropdownCoordinator: dwell completed")
            self.showPanel()
        }
    }

    private func cancelDwellTimer() {
        guard dwellToken != nil else { return }
        dwellToken = nil
        snugLog(" NotchDropdownCoordinator: dwell cancelled")
    }

    // MARK: - Phase 2

    private func showPanel() {
        guard !hiddenItems.isEmpty else {
            snugLog(" NotchDropdownCoordinator: show skipped, no hidden items")
            return
        }

        guard !notchRect.isEmpty else {
            snugLog(" NotchDropdownCoordinator: show skipped, no notch rect")
            return
        }

        panel.show(items: hiddenItems, below: notchRect)
        cursorIsInTrackingZone = isMouseInTrackingZone()
        cursorIsInPanelZone = isMouseInPanelZone()
        cursorIsInZone = cursorIsInTrackingZone || cursorIsInPanelZone
        installActiveMonitors()
        cancelGraceHide()
        snugLog(" NotchDropdownCoordinator: phase2 active")
    }

    private func dismissPanel(animated: Bool, reason: String) {
        cancelDwellTimer()
        cancelGraceHide()
        removeActiveMonitors()
        panel.hide(animated: animated)
        cursorIsInPanelZone = false
        cursorIsInZone = false
        snugLog(" NotchDropdownCoordinator: panel dismissed (%@)", reason)
    }

    private func installActiveMonitors() {
        guard globalMouseMonitor == nil, localEventMonitor == nil else { return }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleMouseActivity()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }

                if event.type == .keyDown, event.keyCode == 53 {
                    snugLog(" NotchDropdownCoordinator: escape pressed")
                    self.dismissPanel(animated: true, reason: "escape")
                    return nil
                }

                if event.type == .mouseMoved {
                    self.handleMouseActivity()
                }

                return event
            }
        }

        snugLog(" NotchDropdownCoordinator: monitors installed")
    }

    private func removeActiveMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        snugLog(" NotchDropdownCoordinator: monitors removed")
    }

    private func handleMouseActivity() {
        guard panel.isVisible else { return }

        cursorIsInTrackingZone = isMouseInTrackingZone()
        cursorIsInPanelZone = isMouseInPanelZone()
        updateCursorZoneState()
    }

    private func updateCursorZoneState() {
        let isInZoneNow = cursorIsInTrackingZone || cursorIsInPanelZone
        guard isInZoneNow != cursorIsInZone else { return }

        cursorIsInZone = isInZoneNow

        if cursorIsInZone {
            snugLog(" NotchDropdownCoordinator: cursor entered active zone")
            cancelGraceHide()
        } else {
            snugLog(" NotchDropdownCoordinator: cursor exited active zone")
            scheduleGraceHide()
        }
    }

    // MARK: - Grace Hide

    private func scheduleGraceHide() {
        let token = UUID()
        graceToken = token
        snugLog(" NotchDropdownCoordinator: grace scheduled")

        DispatchQueue.main.asyncAfter(deadline: .now() + graceDelay) { [weak self] in
            guard let self, self.graceToken == token else { return }
            self.graceToken = nil

            self.cursorIsInTrackingZone = self.isMouseInTrackingZone()
            self.cursorIsInPanelZone = self.isMouseInPanelZone()

            guard !self.cursorIsInTrackingZone, !self.cursorIsInPanelZone else {
                self.cursorIsInZone = true
                snugLog(" NotchDropdownCoordinator: grace expired but cursor returned")
                return
            }

            snugLog(" NotchDropdownCoordinator: grace completed")
            self.dismissPanel(animated: true, reason: "graceTimeout")
        }
    }

    private func cancelGraceHide() {
        guard graceToken != nil else { return }
        graceToken = nil
        snugLog(" NotchDropdownCoordinator: grace cancelled")
    }

    // MARK: - Hit Testing

    private func isMouseInTrackingZone() -> Bool {
        guard let trackingWindow else { return false }
        return trackingWindow.frame.contains(NSEvent.mouseLocation)
    }

    private func isMouseInPanelZone() -> Bool {
        panel.panelFrame.contains(NSEvent.mouseLocation)
    }
}

private final class TrackingWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TrackingView: NSView {

    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }
}
