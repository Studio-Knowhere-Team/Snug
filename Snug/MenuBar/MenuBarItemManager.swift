import AppKit

/// Discovers and tracks menu bar status items using CGWindowList APIs.
/// No special permissions required — basic window metadata (position, size, PID)
/// is available without Screen Recording.
@MainActor
final class MenuBarItemManager {
    private(set) var items: [MenuBarItem] = []

    /// Window IDs of our own NSStatusItems (separator, toggle).
    /// On modern macOS these windows may be owned by a system process,
    /// so PID filtering alone doesn't exclude them.
    var ownWindowIDs: Set<CGWindowID> = []

    private let myBundleID = Bundle.main.bundleIdentifier ?? ""

    /// Cache of PID → bundle identifier
    private var bundleIDCache: [pid_t: String] = [:]

    init() {
        // Clear stale PID cache when screen configuration changes — the
        // PIDs themselves don't change, but running-app state sometimes
        // does on display events. Keep the observer here so the manager
        // owns its cache lifecycle; the StatusBarController owns the
        // refresh cadence (via NSWorkspace observers + heartbeat).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.bundleIDCache.removeAll(keepingCapacity: true)
            }
        }
    }

    // MARK: - Discovery

    /// Enumerate all status bar items currently in the menu bar.
    ///
    /// Uses `.optionAll` deliberately: items pushed off-screen by the
    /// collapse separator live at extreme negative X (outside any
    /// display's bounds) and `.optionOnScreenOnly` would drop them on
    /// some macOS versions, breaking post-collapse discovery. The marginal
    /// cost (`~3–8 ms` with a typical window count) is acceptable at our
    /// call cadence — which, post Step 4, is event-driven rather than 5 s
    /// polling.
    func refreshItems() {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let myPID = ProcessInfo.processInfo.processIdentifier

        var discovered: [MenuBarItem] = []

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 25 // kCGStatusWindowLevel — status bar items
            else { continue }

            guard let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            // Skip our own items.
            // PID check works when macOS lets the app own its status-item windows.
            if ownerPID == myPID { continue }
            if !myBundleID.isEmpty, resolvedBundleID(for: ownerPID) == myBundleID { continue }
            // On modern macOS the windows may be owned by a system process,
            // so also check window IDs we know belong to our status items.
            if ownWindowIDs.contains(windowID) { continue }

            let frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // Skip items with zero or tiny width (invisible)
            guard frame.width > 2 else { continue }

            let title = window[kCGWindowName as String] as? String
            let bundleID = resolvedBundleID(for: ownerPID)

            let item = MenuBarItem(
                windowID: windowID,
                frame: frame,
                ownerPID: ownerPID,
                ownerName: ownerName,
                bundleID: bundleID,
                title: title
            )
            discovered.append(item)
        }

        // Sort left-to-right by position
        items = discovered.sorted { $0.frame.maxX < $1.frame.maxX }
    }

    // MARK: - Bundle ID Resolution

    private func resolvedBundleID(for pid: pid_t) -> String? {
        if let cached = bundleIDCache[pid] {
            return cached
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            let bid = app.bundleIdentifier
            if let bid {
                bundleIDCache[pid] = bid
            }
            return bid
        }
        return nil
    }

}
