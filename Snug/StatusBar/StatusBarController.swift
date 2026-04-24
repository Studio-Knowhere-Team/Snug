import AppKit

@MainActor
final class StatusBarController: NSObject {

    // MARK: - Status Items
    //
    // Two items, right to left in the menu bar:
    //
    //   [pushed items]  [SEP ( ]  [TOGGLE )]  [system items]
    //
    // The separator doubles as the pusher. When collapsed it expands to
    // collapseLength, pushing all items to its left off-screen.
    // The toggle shows a filled circle with the count of pushed items.

    /// The visible toggle button the user clicks to expand / collapse.
    private let toggleItem: NSStatusItem

    /// Left half-circle ( — marks the boundary. Items to its left get pushed.
    /// Also the pusher: icon-width when expanded, collapseLength when collapsed.
    /// Mutable so it can be recreated if the user cmd-drags it to the wrong side.
    private var separatorItem: NSStatusItem

    // MARK: - Menu Bar Item Management

    private let itemManager = MenuBarItemManager()

    // MARK: - State

    private let preferences: AppPreferences
    private var autoHideTimer: Timer?
    private var startupRescanTimer: Timer?
    private var startupRescanTicksRemaining: Int = 0
    private var isToggling = false
    private var isActivatingItem = false

    /// Coalesces rapid `NSWorkspace` launch/terminate notifications into a
    /// single refresh. Set on each event, cancelled on the next, and fired
    /// when ~250 ms of quiet have elapsed. Using `DispatchWorkItem` rather
    /// than `Timer` avoids `Timer.tolerance` batching, which is
    /// counter-productive for a coalescer (we want predictable quiet-time).
    private var workspaceCoalesce: DispatchWorkItem?

    /// Long-interval heartbeat that runs `reconcile()` to catch categories
    /// of state changes that NSWorkspace observers miss: LaunchAgents
    /// already running at Snug startup (no launch notification will fire),
    /// apps that lazily vend `AXExtrasMenuBar` children seconds after their
    /// launch notification, and system services (e.g. VPN indicators) that
    /// aren't apps. Fires on a 60 s tolerance-heavy schedule — silent
    /// unless the reconciled state actually differs from the snapshot.
    private var heartbeatTimer: Timer?

    /// Coalesces `screenParametersChanged` bursts. CoreGraphics fires this
    /// notification 3–7 times over ~800 ms during a normal monitor hotplug,
    /// and sometimes dozens of times during rapid display state churn. We
    /// only want one rediscovery when the storm settles.
    private var screenChangeCoalesce: DispatchWorkItem?

    /// Last-observed set of `NSScreen.screens` frames. A `screenParameters`
    /// notification whose post-debounce screen set equals this is a
    /// CoreGraphics timing glitch, not a real configuration change — we
    /// skip the rediscovery to avoid burning cycles on no-op events.
    private var lastObservedScreenFrames: [CGRect] = []

    /// Width used to push items off-screen (recalculated on screen changes)
    private var collapseLength: CGFloat = 10000

    private(set) var isCollapsed: Bool = false

    // MARK: - Smart Expansion

    /// Natural positions of hidden items captured from fully-expanded state
    private var cachedNaturalPositions: [(windowID: CGWindowID, naturalX: CGFloat)] = []

    /// Cached hidden items for AX name resolution on right-click
    private var cachedHiddenItems: [MenuBarItem] = []

    /// Pre-resolved info (name + icon) from when items were still visible on screen
    private var cachedHiddenItemInfo: [HiddenItemInfo] = []

    /// Item count discovered post-collapse (includes items behind the notch).
    /// CGWindowList sees all items once they're pushed off-screen, even ones
    /// that were invisible at natural width on a notched display.
    private var postCollapseItemCount: Int = 0

    // MARK: - Snapshot (Step 1 of refactor)
    //
    // Shadow of the legacy `cached*` fields. Populated on expand via
    // `synthesizeSnapshotAfterExpand()`; not yet read by any consumer
    // (that's Step 3). Carries a sticky `resolvedNames` ledger so behind-
    // notch names survive screen changes and natural-width scans.
    //
    // INVARIANT (see MenuBarSnapshot doc): `totalCount` must reflect a
    // stable reading, never a single transient value. This is not yet
    // enforced by a write gate (that's Step 2); for now we seed it from
    // `postCollapseItemCount` which carries the legacy behaviour.

    private(set) var currentSnapshot: MenuBarSnapshot = .empty

    // MARK: - Computed Positions

    /// The screen-space x of the separator item's left edge.
    private var separatorOriginX: CGFloat {
        separatorItem.button?.window?.frame.origin.x ?? 0
    }

    /// Tell the item manager which windows belong to us so it can skip them.
    private func registerOwnWindowIDs() {
        var ids = Set<CGWindowID>()
        if let wn = separatorItem.button?.window?.windowNumber,
           let id = UInt32(exactly: wn) { ids.insert(id) }
        if let wn = toggleItem.button?.window?.windowNumber,
           let id = UInt32(exactly: wn) { ids.insert(id) }
        itemManager.ownWindowIDs = ids
    }

    /// If the user cmd-dragged the separator to the RIGHT of the toggle,
    /// collapsing would push the toggle off-screen. Detect this and recreate
    /// the separator so it appears to the left of the toggle again.
    private func ensureSeparatorIsLeftOfToggle() {
        guard let sepWindow = separatorItem.button?.window,
              let togWindow = toggleItem.button?.window else { return }

        let sepX = sepWindow.frame.origin.x
        let togX = togWindow.frame.origin.x

        // Separator should be to the LEFT of the toggle (lower X value).
        // If it's to the right (or exactly overlapping), recreate it.
        guard sepX >= togX else { return }

        snugLog(" Separator on wrong side (sepX=%.0f >= togX=%.0f), recreating", sepX, togX)
        NSStatusBar.system.removeStatusItem(separatorItem)
        separatorItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = separatorItem.button {
            button.image = Self.makeSeparatorIcon()
        }
        registerOwnWindowIDs()
    }

    // MARK: - Init

    init(preferences: AppPreferences = .shared) {
        self.preferences = preferences

        // Creation order determines initial position (rightmost first).
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()
        setup()
    }

    private func setup() {
        lastObservedScreenFrames = NSScreen.screens.map { $0.frame }
        updateCollapseLength()

        // Configure separator — left half-circle  (
        if let button = separatorItem.button {
            button.image = Self.makeSeparatorIcon()
        }

        // Configure toggle button
        if let button = toggleItem.button {
            button.image = Self.makeCollapsedIcon(count: 0)
            button.target = self
            button.action = #selector(toggleButtonPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        preferences.onPreferencesChanged = { [weak self] in
            self?.handlePreferencesChanged()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Event-driven refresh: when an app launches or terminates with an
        // activation policy that permits menu-bar extras, schedule a
        // coalesced rediscovery. Replaces the old 5 s periodic
        // `MenuBarItemManager.refreshItems` poll that ran forever.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Safety-net heartbeat. 60 s is long enough that the steady-state
        // cost is negligible and the coalesced tolerance lets macOS batch
        // wakeups; short enough that a missed launch notification or a
        // lazily-vended AX extra gets picked up within a minute.
        let heartbeat = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        heartbeat.tolerance = 10
        heartbeatTimer = heartbeat

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.registerOwnWindowIDs()

            // Discover items at natural width before the first collapse,
            // so the badge count and dropdown are populated immediately.
            self.itemManager.refreshItems()
            let hidden = self.itemsLeftOfSeparator()
            self.cachedNaturalPositions = hidden
                .map { (windowID: $0.windowID, naturalX: $0.frame.minX) }
            self.cachedHiddenItems = hidden
            self.cachedHiddenItemInfo = AccessibilityMenuBarHelper.resolveItems(for: hidden)
            snugLog(" setup: resolved %d items at natural width: %@",
                  self.cachedHiddenItemInfo.count,
                  self.cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))
            self.synthesizeSnapshot(width: .natural)

            self.collapseMenuBar()
            self.startStartupRescan()
        }
    }

    // MARK: - Startup Rescan

    /// After login some apps load their status items several seconds after
    /// Snug's initial collapse. Re-run discovery for ~10 s so the badge
    /// count catches up as late-loading items appear.
    ///
    /// Reduced in Step 4 from 6 ticks (30 s) to 2 ticks (10 s) now that
    /// NSWorkspace launch observers + the 60 s heartbeat cover the longer-
    /// tail cases. The short rescan stays because some apps register
    /// their `AXExtrasMenuBar` a second or two after their launch
    /// notification fires — polling briefly at boot is cheaper than
    /// adding a per-app post-launch retry for every app.
    private func startStartupRescan() {
        startupRescanTimer?.invalidate()
        startupRescanTicksRemaining = 2  // 2 × 5 s = 10 s
        startupRescanTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(startupRescanTick),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func startupRescanTick() {
        startupRescanTicksRemaining -= 1
        if isCollapsed {
            postCollapseDiscovery()
        }
        if startupRescanTicksRemaining <= 0 {
            startupRescanTimer?.invalidate()
            startupRescanTimer = nil
            snugLog("startupRescan: finished")
        }
    }

    // MARK: - Icons

    private static let circleR: CGFloat = 6
    private static let circleCY: CGFloat = 9
    private static let iconLW: CGFloat = 1.5

    /// Left half-circle  (
    private static func makeSeparatorIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 9, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let path = NSBezierPath()
            path.lineWidth = iconLW
            path.lineCapStyle = .round
            path.appendArc(withCenter: NSPoint(x: 7, y: circleCY),
                           radius: circleR,
                           startAngle: 90, endAngle: 270)
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full outlined circle  ○
    private static func makeExpandedIcon() -> NSImage {
        let d = circleR * 2
        let w = d + 4
        let cx = w / 2
        let image = NSImage(size: NSSize(width: w, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let path = NSBezierPath(ovalIn: NSRect(x: cx - circleR, y: circleCY - circleR,
                                                    width: d, height: d))
            path.lineWidth = iconLW
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Toggle icon when collapsed: left half-circle + filled circle.
    /// The arc radius matches the filled circle so they look like a pair.
    ///   count == 0 → ( + small filled solid circle
    ///   count  > 0 → ( + filled circle with count cut out
    private static func makeCollapsedIcon(count: Int) -> NSImage {
        let pad: CGFloat = 1   // padding on each side
        let gap: CGFloat = 1   // space between arc right edge and filled circle left edge
        let h: CGFloat = 18
        let cy = h / 2

        if count <= 0 {
            let r = circleR                          // 6 — both arc and fill
            let arcCX = pad + r                      // arc center; rightmost point of arc
            let filledCX = arcCX + gap + r           // filled circle center
            let w = filledCX + r + pad               // total image width

            let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
                // Left half-circle ( — matching radius
                NSColor.black.setStroke()
                let arc = NSBezierPath()
                arc.lineWidth = iconLW
                arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: arcCX, y: cy),
                              radius: r, startAngle: 90, endAngle: 270)
                arc.stroke()

                // Filled circle
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: filledCX - r, y: cy - r,
                                            width: r * 2, height: r * 2)).fill()
                return true
            }
            image.isTemplate = true
            return image
        }

        let r: CGFloat = 8                          // filled circle radius (original size)
        let arcHR: CGFloat = 3                       // horizontal radius (narrow)
        let arcVR = r - 2                            // vertical radius matches filled circle
        let arcCX = pad + arcHR                      // arc center X
        let filledCX = arcCX + gap + r               // filled circle center
        let w = filledCX + r + pad                   // total image width

        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            // Elliptical arc ( — tall & narrow, peeks from behind the circle
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: .zero, radius: 1.0,
                          startAngle: 90, endAngle: 270)
            var xform = AffineTransform.identity
            xform.translate(x: arcCX, y: cy)
            xform.scale(x: arcHR, y: arcVR)
            arc.transform(using: xform)
            arc.lineWidth = iconLW
            arc.lineCapStyle = .round
            arc.stroke()

            // Filled circle with count
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: filledCX - r, y: cy - r,
                                        width: r * 2, height: r * 2)).fill()

            let text = count > 9 ? "9+" : "\(count)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let ts = text.size(withAttributes: attrs)

            NSGraphicsContext.current?.compositingOperation = .clear
            text.draw(at: NSPoint(x: filledCX - ts.width / 2,
                                  y: cy - ts.height / 2),
                      withAttributes: attrs)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Hidden Items

    /// Items to the left of the separator, filtered to the separator's display.
    ///
    /// Filtering to one display is essential in multi-monitor setups — without
    /// it, CGWindowList can return the same logical status item multiple times
    /// (once per display) and items from displays placed to the left of the
    /// separator's display also pass the naive `midX < sepX` check. Display
    /// mismatches between calls are handled by `refreshHiddenItemCache`'s
    /// merge logic, which preserves previously-discovered items rather than
    /// overwriting the cache on every scan.
    private func itemsLeftOfSeparator() -> [MenuBarItem] {
        let sepX = separatorOriginX

        guard let screen = separatorItem.button?.window?.screen,
              let screenNumber = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return itemManager.items.filter { $0.frame.midX < sepX }
        }

        let db = CGDisplayBounds(screenNumber)

        return itemManager.items.filter { item in
            let mx = item.frame.midX
            let my = item.frame.midY
            return mx >= db.origin.x && mx < db.origin.x + db.size.width &&
                   my >= db.origin.y && my < db.origin.y + db.size.height &&
                   mx < sepX
        }
    }

    /// Items to the left of the separator WITHOUT X-bounds filtering.
    /// After collapse, items are pushed off-screen (negative X) and the
    /// normal display-bounds check rejects them. This variant only checks
    /// that the item is at the correct menu-bar Y level.
    private func allItemsPushedBySeparator() -> [MenuBarItem] {
        let sepX = separatorOriginX

        guard let screen = separatorItem.button?.window?.screen,
              let screenNumber = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return itemManager.items.filter { $0.frame.midX < sepX }
        }

        let db = CGDisplayBounds(screenNumber)

        return itemManager.items.filter { item in
            let my = item.frame.midY
            // Y must be in the menu bar band, X just needs to be left of separator
            return my >= db.origin.y && my < db.origin.y + db.size.height &&
                   item.frame.midX < sepX
        }
    }

    // MARK: - Smart Expansion

    /// Briefly go to natural width, capture item positions, then call completion.
    /// Strip " (N)" suffix from display name for comparison.
    private func baseName(of displayName: String) -> String {
        if let range = displayName.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            return String(displayName[..<range.lowerBound])
        }
        return displayName
    }

    // MARK: - Toggle Icon

    /// Count of hidden items for the badge. Prefers the AX-resolved count
    /// (has names), falls back to the CGWindowList count (works without AX).
    ///
    /// Reads through `currentSnapshot` so the badge reflects the atomic
    /// state — no torn read between `items.count` and `totalCount`.
    private var hiddenItemCount: Int {
        let live = currentSnapshot.items.count
        return live > 0 ? live : currentSnapshot.totalCount
    }

    private func updateToggleIcon(animated: Bool = true) {
        let newImage = isCollapsed
            ? Self.makeCollapsedIcon(count: hiddenItemCount)
            : Self.makeExpandedIcon()

        guard let button = toggleItem.button else { return }

        if animated {
            button.wantsLayer = true
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.15
            button.layer?.add(transition, forKey: "iconFade")
        }

        button.image = newImage
    }

    // MARK: - Collapse / Expand

    func expandCollapseIfNeeded() {
        guard !isToggling else { return }
        isToggling = true

        if isCollapsed {
            expandMenuBar()
        } else {
            collapseMenuBar()
        }
    }

    private func collapseMenuBar() {
        // Safety: if the separator was cmd-dragged to the wrong side, fix it.
        ensureSeparatorIsLeftOfToggle()

        snugLog(" collapseMenuBar: isCollapsed=%d, cachedNaturalPositions=%d, cachedHiddenItems=%d, cachedHiddenItemInfo=%d",
              isCollapsed ? 1 : 0,
              cachedNaturalPositions.count, cachedHiddenItems.count, cachedHiddenItemInfo.count)

        // Capture positions before collapse (items at natural width).
        if !isCollapsed && cachedNaturalPositions.isEmpty {
            itemManager.refreshItems()
            let hidden = itemsLeftOfSeparator()
            cachedNaturalPositions = hidden
                .map { (windowID: $0.windowID, naturalX: $0.frame.minX) }
            cachedHiddenItems = hidden
            snugLog(" collapseMenuBar: captured %d natural positions", hidden.count)
        }

        // Resolve names while items are still on-screen (AX needs visible positions).
        if !isCollapsed && cachedHiddenItemInfo.isEmpty {
            cachedHiddenItemInfo = AccessibilityMenuBarHelper.resolveItems(for: cachedHiddenItems)
            snugLog(" collapseMenuBar: resolved %d item names: %@",
                  cachedHiddenItemInfo.count,
                  cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))
        }

        // Capture the snapshot now — items are still at natural width, so
        // resolvedNames picked up this cycle won't be replaced by a later
        // post-collapse scan that only sees Control-Centre-owned windows.
        synthesizeSnapshot(width: .natural)

        isCollapsed = true
        updateToggleIcon()

        autoHideTimer?.invalidate()
        autoHideTimer = nil

        // Recalculate in case screen changed or initial value was stale.
        updateCollapseLength()
        separatorItem.length = collapseLength
        isToggling = false

        // Post-collapse: after the separator has pushed ALL items off-screen,
        // re-count using relaxed bounds. Items hidden behind the notch at
        // natural width now have windows at negative-X positions.
        postCollapseDiscovery()
    }

    /// After collapse, refresh CGWindowList without X-bounds filtering to
    /// find items that were invisible at natural width (behind the notch).
    /// Updates the hidden item count AND resolves info for newly discovered items
    /// so they appear in the right-click context menu.
    ///
    /// Rewritten in Step 6 to use structured concurrency so the per-app
    /// AX scan can await its off-main worker without blocking the main
    /// actor across the 0.3 s settle delay + the scan itself.
    private func postCollapseDiscovery() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.isCollapsed else { return }

            self.itemManager.refreshItems()
            let allPushed = self.allItemsPushedBySeparator()

            // Prune entries whose owning app has quit — their PID is no longer
            // running, so the menu bar item no longer exists. Without this the
            // badge stays stale until the next expand/collapse.
            let beforePrune = self.cachedHiddenItemInfo.count
            self.cachedHiddenItemInfo.removeAll { info in
                NSRunningApplication(processIdentifier: info.ownerPID) == nil
            }
            if self.cachedHiddenItemInfo.count != beforePrune {
                snugLog(" postCollapseDiscovery: pruned %d entries for quit apps",
                      beforePrune - self.cachedHiddenItemInfo.count)
                self.updateToggleIcon()
            }

            // Snapshot the cache names up front so we can detect real changes
            // and only log when something actually moved — avoids spamming the
            // log every startup-rescan tick when nothing has changed.
            let namesBefore = self.cachedHiddenItemInfo.map { $0.name }

            if allPushed.count != self.postCollapseItemCount {
                snugLog(" postCollapseDiscovery: count %d → %d",
                      self.postCollapseItemCount, allPushed.count)
                self.postCollapseItemCount = allPushed.count
            }

            // Find items discovered post-collapse that weren't in the natural-width scan.
            let knownIDs = Set(self.cachedHiddenItems.map { $0.windowID })
            let newItems = allPushed.filter { !knownIDs.contains($0.windowID) }

            if !newItems.isEmpty {
                let newInfo = Self.resolveItemsByProcess(newItems)
                let existingNames = Set(self.cachedHiddenItemInfo.map { self.baseName(of: $0.name) })
                let uniqueNew = newInfo.filter { !existingNames.contains(self.baseName(of: $0.name)) }
                if !uniqueNew.isEmpty {
                    snugLog(" postCollapseDiscovery: resolved %d new by process: %@",
                          uniqueNew.count, uniqueNew.map { $0.name }.joined(separator: ", "))
                    self.cachedHiddenItemInfo.append(contentsOf: uniqueNew)
                    self.cachedHiddenItemInfo.sort { $0.name < $1.name }
                }
            }

            // Walk every running app and ask it directly for its own
            // AXExtrasMenuBar — but ONLY if we're missing names for hidden
            // items. This is the only path that can name behind-the-notch
            // items on a notched MBP (CGWindowList reports their owner as
            // Control Centre, which we skip). The per-app scan is flaky,
            // though: during display transitions or while a status item is
            // being realized it will briefly return apps whose extras are
            // actually *visible* on the right of the separator, with zero AX
            // frames. Gating it on the gap (`allPushed` is CGWindowList-
            // authoritative post-collapse) means we don't add phantoms when
            // the cache is already complete.
            let toggleX = self.toggleItem.button?.window?.frame.origin.x ?? CGFloat.greatestFiniteMagnitude
            let gap = max(0, allPushed.count - self.cachedHiddenItemInfo.count)
            if gap > 0 {
                let byApp = await AccessibilityMenuBarHelper.enumerateExtrasByRunningApps(leftOf: toggleX)
                let existingNamesNow = Set(self.cachedHiddenItemInfo.map { self.baseName(of: $0.name) })
                let newFromApps = byApp.filter { !existingNamesNow.contains(self.baseName(of: $0.name)) }
                let limited = Array(newFromApps.prefix(gap))
                if !limited.isEmpty {
                    snugLog(" postCollapseDiscovery: resolved %d new by per-app scan: %@",
                          limited.count, limited.map { $0.name }.joined(separator: ", "))
                    self.cachedHiddenItemInfo.append(contentsOf: limited)
                    self.cachedHiddenItemInfo.sort { $0.name < $1.name }
                }
            }

            // Trim cache if it's overshot the authoritative count (this
            // happens when a prior merge ran before the gap-gate, or when
            // apps drop their extras without quitting). Prefer to drop
            // `windowID == 0` entries first — those came from per-app
            // enumeration and are lower-confidence than CGWindowList-sourced
            // entries.
            if allPushed.count > 0 && self.cachedHiddenItemInfo.count > allPushed.count {
                let before = self.cachedHiddenItemInfo.count
                let ranked = self.cachedHiddenItemInfo.sorted { a, b in
                    if (a.windowID != 0) != (b.windowID != 0) {
                        return a.windowID != 0  // keep CGWindowList-sourced first
                    }
                    return a.name < b.name
                }
                self.cachedHiddenItemInfo = Array(ranked.prefix(allPushed.count))
                    .sorted { $0.name < $1.name }
                snugLog(" postCollapseDiscovery: trimmed %d stale entries (cache %d → %d)",
                      before - self.cachedHiddenItemInfo.count,
                      before, self.cachedHiddenItemInfo.count)
            }

            // Only emit the DONE summary when the cache actually changed.
            let namesAfter = self.cachedHiddenItemInfo.map { $0.name }
            if namesAfter != namesBefore {
                snugLog(" postCollapseDiscovery DONE: %d items: %@",
                      namesAfter.count, namesAfter.joined(separator: ", "))
            }

            // Atomically replace the snapshot with the post-collapse state.
            self.synthesizeSnapshot(width: .collapsed)

            // Refresh the icon if the count may have changed.
            self.updateToggleIcon()
        }
    }

    /// Resolve hidden item info using process metadata (for items not resolvable via AX position).
    /// Used for behind-notch items that are only discoverable post-collapse via CGWindowList.
    private static func resolveItemsByProcess(_ items: [MenuBarItem]) -> [HiddenItemInfo] {
        var seen: [String: (icon: NSImage?, frame: CGRect, windowID: CGWindowID, ownerPID: pid_t)] = [:]
        var counts: [String: Int] = [:]

        for item in items {
            let app = NSRunningApplication(processIdentifier: item.ownerPID)
            let name = app?.localizedName ?? item.ownerName
            guard !name.isEmpty else { continue }
            // Skip Control Centre — it hosts third-party items on modern macOS,
            // so grouping by its name is meaningless.
            guard name != "Control Centre" && name != "Control Center" else { continue }
            // Skip Window Server — it briefly owns phantom duplicate status-item
            // windows during Control Centre replication events (visible in
            // CGWindowList but not real, user-facing menu bar extras).
            guard name != "Window Server" else { continue }
            // Skip system widgets
            guard !AccessibilityMenuBarHelper.systemWidgetNames.contains(name) else { continue }

            counts[name, default: 0] += 1
            if seen[name] == nil {
                let icon = app?.icon?.scaled(to: NSSize(width: 16, height: 16))
                seen[name] = (icon: icon, frame: item.frame, windowID: item.windowID, ownerPID: item.ownerPID)
            }
        }

        return counts.sorted(by: { $0.key < $1.key }).compactMap { name, count in
            guard let data = seen[name] else { return nil }
            let displayName = count > 1 ? "\(name) (\(count))" : name
            return HiddenItemInfo(name: displayName, icon: data.icon, frame: data.frame, windowID: data.windowID, ownerPID: data.ownerPID)
        }
    }

    private func expandMenuBar() {
        // Safety: if the separator was cmd-dragged to the wrong side, fix it.
        ensureSeparatorIsLeftOfToggle()

        snugLog(" expandMenuBar: cachedHiddenItemInfo=%d",
              cachedHiddenItemInfo.count)

        // Update the toggle icon first (fade) so it transitions smoothly
        // at the same moment the items appear — not 250ms after.
        isCollapsed = false
        updateToggleIcon()

        // Reveal items instantly.
        separatorItem.length = NSStatusItem.variableLength

        // Always reset synchronously — don't gate on the async callback.
        isToggling = false

        // Refresh caches after items have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.refreshHiddenItemCache()
            self.autoCollapseIfNeeded()
        }
    }

    /// Refresh hidden item caches after expand (items are at natural positions).
    private func refreshHiddenItemCache() {
        itemManager.refreshItems()
        let hidden = itemsLeftOfSeparator()
        cachedNaturalPositions = hidden
            .map { (windowID: $0.windowID, naturalX: $0.frame.minX) }
        cachedHiddenItems = hidden

        // Merge fresh discovery with the existing cache, but cap the result
        // at the authoritative count (max of `hidden.count` and the last
        // post-collapse count). Fresh discovery at expanded width can miss
        // items that only become visible post-collapse (behind the notch),
        // so we preserve prior entries to fill that gap — but never beyond
        // the true count. Preserved entries are ranked so that the
        // highest-confidence (CGWindowList-sourced, `windowID != 0`) ones
        // survive when trimming. Quit-app pruning happens in
        // postCollapseDiscovery.
        let freshInfo = AccessibilityMenuBarHelper.resolveItems(for: hidden)
        let freshNames = Set(freshInfo.map { baseName(of: $0.name) })
        let preserved = cachedHiddenItemInfo.filter {
            !freshNames.contains(baseName(of: $0.name))
        }
        let target = max(hidden.count, postCollapseItemCount)
        let slotsForPreserved = max(0, target - freshInfo.count)
        let rankedPreserved = preserved.sorted { a, b in
            if (a.windowID != 0) != (b.windowID != 0) {
                return a.windowID != 0
            }
            return a.name < b.name
        }
        let keptPreserved = Array(rankedPreserved.prefix(slotsForPreserved))
        cachedHiddenItemInfo = (freshInfo + keptPreserved)
            .sorted { $0.name < $1.name }
        snugLog(" refreshHiddenItemCache: hidden=%d, resolved=%d",
              hidden.count, cachedHiddenItemInfo.count)

        synthesizeSnapshot(width: .natural)
    }

    /// Rebuild `currentSnapshot` from the legacy `cached*` fields.
    ///
    /// Called from every site that mutates the cached fields. Seeds
    /// `resolvedNames` from the prior snapshot so names for items missing
    /// in this scan (e.g. behind the notch when we're at natural width)
    /// survive in the ledger.
    ///
    /// INVARIANT (enforced by DEBUG assertions): after this call returns,
    /// `currentSnapshot.items.count == cachedHiddenItemInfo.count` and
    /// `currentSnapshot.totalCount >= cachedHiddenItemInfo.count`. If any
    /// of these fail in a DEBUG build, a mutation path updated a cached
    /// field without calling synthesizeSnapshot afterward.
    private func synthesizeSnapshot(width: MenuBarSnapshot.Width) {
        var positions: [MenuBarSnapshot.StableKey: CGFloat] = [:]
        for (windowID, naturalX) in cachedNaturalPositions {
            if let item = cachedHiddenItems.first(where: { $0.windowID == windowID }) {
                let key = MenuBarSnapshot.StableKey(ownerPID: item.ownerPID)
                positions[key] = naturalX
            }
        }

        var names = currentSnapshot.resolvedNames
        for info in cachedHiddenItemInfo {
            let key = MenuBarSnapshot.StableKey(ownerPID: info.ownerPID)
            names[key] = info.name
        }

        currentSnapshot = MenuBarSnapshot(
            items: cachedHiddenItemInfo,
            totalCount: max(cachedHiddenItemInfo.count, postCollapseItemCount),
            naturalPositions: positions,
            resolvedNames: names,
            capturedAt: Date(),
            capturedWidth: width
        )

        #if DEBUG
        assert(
            currentSnapshot.items.count == cachedHiddenItemInfo.count,
            "snapshot/legacy divergence on items.count: snapshot=\(currentSnapshot.items.count) legacy=\(cachedHiddenItemInfo.count)"
        )
        assert(
            currentSnapshot.totalCount >= cachedHiddenItemInfo.count,
            "snapshot totalCount (\(currentSnapshot.totalCount)) must be >= items.count (\(cachedHiddenItemInfo.count))"
        )
        if postCollapseItemCount > 0 {
            assert(
                currentSnapshot.totalCount >= postCollapseItemCount,
                "snapshot totalCount (\(currentSnapshot.totalCount)) must carry postCollapseItemCount (\(postCollapseItemCount))"
            )
        }
        #endif
    }

    // MARK: - Auto-Collapse Timer

    private func autoCollapseIfNeeded() {
        guard preferences.isAutoHide, !isCollapsed else { return }
        startAutoHideTimer()
    }

    private func startAutoHideTimer() {
        autoHideTimer?.invalidate()
        let interval = preferences.autoHideInterval.seconds
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.preferences.isAutoHide else { return }
                self.collapseMenuBar()
            }
        }
    }

    // MARK: - Collapse Width

    private func updateCollapseLength() {
        // Calculate total span across ALL connected displays so items
        // are pushed off-screen even in multi-monitor setups (e.g. an
        // ultrawide to the left of a MacBook).
        let screens = NSScreen.screens
        let minX = screens.map { $0.frame.minX }.min() ?? 0
        let maxX = screens.map { $0.frame.maxX }.max() ?? 1728
        let totalSpan = maxX - minX
        let newLength = max(totalSpan + 500, 500)

        let wasCollapsed = isCollapsed
        collapseLength = newLength

        if wasCollapsed {
            separatorItem.length = collapseLength
        }
    }

    // MARK: - Actions

    @objc private func toggleButtonPressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        let isRightClick = event.type == .rightMouseUp || event.modifierFlags.contains(.control)

        if isRightClick {
            showContextMenu()
        } else {
            expandCollapseIfNeeded()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // Show all hidden items when collapsed. Read through currentSnapshot
        // so the menu built here is atomic with respect to any ongoing
        // discovery — a mid-discovery mutation cannot tear the items list.
        let allItems = isCollapsed ? currentSnapshot.items : []

        snugLog(" showContextMenu: items=%d, isCollapsed=%d",
              allItems.count, isCollapsed ? 1 : 0)

        for info in allItems {
            let menuItem = NSMenuItem(
                title: info.name,
                action: #selector(hiddenItemClicked(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = info
            if let icon = info.icon {
                menuItem.image = icon
            }
            menu.addItem(menuItem)
        }

        if !allItems.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(
            title: "Quit Snug",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.toggleItem.menu = nil
        }
    }

    /// Handle clicking a hidden item in the context menu.
    /// Expands to natural width, Cmd+drags the item next to the separator,
    /// then AXPresses it so its menu opens in the right place.
    @objc private func hiddenItemClicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? HiddenItemInfo else { return }
        activateHiddenItem(info)
    }

    func activateHiddenItem(_ info: HiddenItemInfo) {
        guard !isActivatingItem else { return }
        isActivatingItem = true

        snugLog(" activateHiddenItem: '%@' ownerPID=%d", info.name, info.ownerPID)

        // Expand to natural width — items must be on-screen for Cmd+drag.
        separatorItem.length = NSStatusItem.variableLength
        isCollapsed = false
        updateToggleIcon()

        // After expansion settles, move the item next to the separator then press it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }

            self.itemManager.refreshItems()
            let freshFrame = self.itemManager.items
                .first(where: { $0.windowID == info.windowID })?.frame ?? info.frame

            // Target: just to the left of the separator (which is just left of our toggle).
            let sepX = self.separatorOriginX
            let targetX = sepX - 10  // a few px left of separator

            // Menu bar Y in Quartz coords (top-left origin, typically ~12).
            let menuBarY = freshFrame.midY

            snugLog(" activateHiddenItem: item at x=%.0f, separator at x=%.0f, target x=%.0f",
                  freshFrame.midX, sepX, targetX)

            // Only drag if the item isn't already next to the separator.
            if abs(freshFrame.midX - targetX) > 30 {
                // Dispatch the Cmd+drag on a background thread so the usleep
                // calls don't block the main run loop.
                DispatchQueue.global(qos: .userInteractive).async {
                    let moved = AccessibilityMenuBarHelper.moveItem(
                        from: freshFrame.midX,
                        to: targetX,
                        menuBarY: menuBarY
                    )
                    snugLog(" activateHiddenItem: moveItem=%d", moved ? 1 : 0)

                    // Back to main thread to press and collapse.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self else { return }
                        // Re-fetch position after the move.
                        self.itemManager.refreshItems()
                        let movedFrame = self.itemManager.items
                            .first(where: { $0.windowID == info.windowID })?.frame ?? freshFrame

                        let pressed = AccessibilityMenuBarHelper.pressItem(
                            named: info.name,
                            ownerPID: info.ownerPID,
                            fallbackFrame: movedFrame
                        )
                        if !pressed {
                            snugLog(" activateHiddenItem: AXPress failed for '%@'", info.name)
                        }
                        self.isActivatingItem = false
                        self.autoCollapseIfNeeded()
                    }
                }
            } else {
                // Already close enough — just press it.
                let pressed = AccessibilityMenuBarHelper.pressItem(
                    named: info.name,
                    ownerPID: info.ownerPID,
                    fallbackFrame: freshFrame
                )
                if !pressed {
                    snugLog(" activateHiddenItem: AXPress failed for '%@'", info.name)
                }
                self.isActivatingItem = false
                self.autoCollapseIfNeeded()
            }
        }
    }

    @objc private func openPreferences() {
        SettingsOpener.open()
    }

    // MARK: - Preference Change Handlers

    private func handlePreferencesChanged() {
        if preferences.isAutoHide {
            autoCollapseIfNeeded()
        } else {
            autoHideTimer?.invalidate()
            autoHideTimer = nil
        }
    }

    // MARK: - Workspace Events

    /// Apps with prohibited activation policy can't register status items,
    /// so notifications for them get dropped at the source. Anything else
    /// (regular + accessory) warrants a discovery refresh.
    private func workspaceAppIsRelevant(_ note: Notification) -> Bool {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else { return false }
        return app.activationPolicy != .prohibited
    }

    @objc private func workspaceAppLaunched(_ note: Notification) {
        guard workspaceAppIsRelevant(note) else { return }
        scheduleWorkspaceRefresh()
    }

    @objc private func workspaceAppTerminated(_ note: Notification) {
        guard workspaceAppIsRelevant(note) else { return }
        scheduleWorkspaceRefresh()
    }

    /// Debounce launch/terminate bursts into a single rediscovery. Login
    /// storms can fire 30+ launch notifications in 2–3 s; we only need one
    /// refresh after things settle.
    private func scheduleWorkspaceRefresh() {
        workspaceCoalesce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isCollapsed {
                self.postCollapseDiscovery()
            } else {
                self.refreshHiddenItemCache()
            }
        }
        workspaceCoalesce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Heartbeat reconciliation. Runs every ~60 s; only emits a log line
    /// if the reconciled state actually differs from the current snapshot.
    /// Covers categories NSWorkspace observers miss: LaunchAgents already
    /// running at Snug startup, apps that lazily register AX extras, and
    /// non-app system services.
    private func reconcile() {
        let countBefore = currentSnapshot.items.count
        if isCollapsed {
            postCollapseDiscovery()
        } else {
            refreshHiddenItemCache()
        }
        // postCollapseDiscovery is async (0.3 s delay); for the log diff
        // we'll rely on its own DONE line when the cache actually moves.
        // Log only if the snapshot we have right now doesn't match count.
        let countAfter = currentSnapshot.items.count
        if countBefore != countAfter {
            snugLog(" reconcile: count %d → %d", countBefore, countAfter)
        }
    }

    // MARK: - Screen Changes

    @objc private func screenParametersChanged() {
        // Trailing-edge debounce. Wait 200 ms of quiet before acting — long
        // enough to coalesce the 3–7 CoreGraphics events of a monitor
        // hotplug, short enough to be imperceptible as lag.
        screenChangeCoalesce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.handleScreenChangeSettled()
        }
        screenChangeCoalesce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// Runs once after a screen-change storm has settled (see
    /// `screenParametersChanged`). Short-circuits if the screen
    /// configuration is identical to the last observation — this catches
    /// CoreGraphics timing glitches (`Invalid new timing data reported for
    /// display…`) that fire `screenParametersChanged` without an actual
    /// geometry change.
    private func handleScreenChangeSettled() {
        let currentFrames = NSScreen.screens.map { $0.frame }
        if currentFrames == lastObservedScreenFrames {
            return
        }
        lastObservedScreenFrames = currentFrames

        autoHideTimer?.invalidate()
        autoHideTimer = nil
        // Preserve cachedHiddenItems / cachedHiddenItemInfo through sleep/wake.
        // Names can only be resolved at natural (expanded) width, and on wake
        // the app stays collapsed — so clearing the caches here leaves the
        // right-click menu empty until the user manually expand/collapses.
        // Positions can still be stale, so only drop cachedNaturalPositions.
        cachedNaturalPositions = []
        synthesizeSnapshot(width: isCollapsed ? .collapsed : .natural)
        isActivatingItem = false
        updateCollapseLength()

        if isCollapsed {
            postCollapseDiscovery()
        } else {
            refreshHiddenItemCache()
        }
    }
}
