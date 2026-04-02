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
    private var notchDropdownCoordinator: NotchDropdownCoordinator?

    // MARK: - State

    private let preferences: AppPreferences
    private let shouldScheduleInitialSetupWork: Bool
    private var autoHideTimer: Timer?
    private var startupRescanTimer: Timer?
    private var startupRescanTicksRemaining: Int = 0
    private var isToggling = false
    private var isActivatingItem = false

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

    /// Whether the current display has a notch
    private var hasNotch: Bool = false

    /// Cached notch rect — the notch is a physical screen property that rarely
    /// changes. Recalculated only on screen-parameter changes.
    private var cachedNotchRect: CGRect = .zero

    /// The leftmost safe X position (right edge of notch zone)
    private var safeLeftX: CGFloat = 80

    /// Item count discovered post-collapse (includes items behind the notch).
    /// CGWindowList sees all items once they're pushed off-screen, even ones
    /// that were invisible at natural width on a notched display.
    private var postCollapseItemCount: Int = 0

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

    init(preferences: AppPreferences = .shared, scheduleInitialSetupWork: Bool = true) {
        self.preferences = preferences
        self.shouldScheduleInitialSetupWork = scheduleInitialSetupWork

        // Creation order determines initial position (rightmost first).
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()
        setup()
    }

    private func setup() {
        calculateSafeLeftX()
        setupNotchDropdown()
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

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeFromSleep),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        guard shouldScheduleInitialSetupWork else { return }

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
            self.updateNotchDropdownItems()
            snugLog(" setup: resolved %d items at natural width: %@",
                  self.cachedHiddenItemInfo.count,
                  self.cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))

            self.collapseMenuBar()
            self.startStartupRescan()
        }
    }

    // MARK: - Startup Rescan

    /// After login many apps load their status items several seconds after
    /// Snug's initial collapse. Re-run discovery periodically for 30 s so
    /// the badge count catches up as late-loading items appear.
    private func startStartupRescan() {
        startupRescanTimer?.invalidate()
        startupRescanTicksRemaining = 6  // 6 × 5 s = 30 s
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
        snugLog("startupRescan: tick (remaining=%d, isCollapsed=%d)",
              startupRescanTicksRemaining, isCollapsed ? 1 : 0)
        if isCollapsed {
            postCollapseDiscovery()
        }
        if startupRescanTicksRemaining <= 0 {
            startupRescanTimer?.invalidate()
            startupRescanTimer = nil
            snugLog("startupRescan: finished")
        }
    }

    private func setupNotchDropdown() {
        guard hasNotch, preferences.isPocketEnabled else {
            notchDropdownCoordinator?.stop()
            notchDropdownCoordinator = nil
            return
        }

        // Stop old coordinator before creating replacement to avoid
        // overlapping event monitors during ARC deallocation window.
        notchDropdownCoordinator?.stop()
        notchDropdownCoordinator = nil

        let coordinator = NotchDropdownCoordinator()
        coordinator.onItemActivated = { [weak self] info in
            self?.activateHiddenItem(info)
        }
        notchDropdownCoordinator = coordinator
        coordinator.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)
    }

    private func updateNotchDropdownItems() {
        guard let notchDropdownCoordinator else { return }
        notchDropdownCoordinator.updateItems(cachedHiddenItemInfo)
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

    // MARK: - Notch Detection

    private func calculateNotchRect() -> CGRect {
        guard let screen = toggleItem.button?.window?.screen ?? NSScreen.screens.first else {
            snugLog(" calculateNotchRect: x=0 y=0 width=0 height=0")
            return .zero
        }

        let notchHeight = screen.safeAreaInsets.top
        guard notchHeight > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea
        else {
            snugLog(" calculateNotchRect: x=0 y=0 width=0 height=0")
            return .zero
        }

        let notchMinX = screen.frame.origin.x + leftArea.maxX
        let notchMaxX = screen.frame.origin.x + rightArea.minX
        let notchWidth = notchMaxX - notchMinX

        guard notchWidth > 0 else {
            snugLog(" calculateNotchRect: x=0 y=0 width=0 height=0")
            return .zero
        }

        let notchRect = CGRect(
            x: notchMinX,
            y: screen.frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        snugLog(" calculateNotchRect: x=%.0f y=%.0f width=%.0f height=%.0f",
              notchRect.origin.x, notchRect.origin.y, notchRect.width, notchRect.height)
        return notchRect
    }

    private func calculateSafeLeftX() {
        // NSStatusBar.system.thickness is deprecated and always returns 22 —
        // useless for notch detection. Use NSScreen.safeAreaInsets instead:
        // on notched MacBooks, safeAreaInsets.top > 0.
        let notchRect = calculateNotchRect()
        hasNotch = !notchRect.isEmpty
        safeLeftX = hasNotch ? notchRect.maxX : 80

        // Cache the notch rect — it's a physical screen property that doesn't
        // change until a display connect/disconnect event.
        if !notchRect.isEmpty {
            cachedNotchRect = notchRect
        }

        snugLog(" calculateSafeLeftX: hasNotch=%d, safeLeftX=%.0f, cachedNotchRect=(%.0f, %.0f, %.0f, %.0f)",
              hasNotch ? 1 : 0, safeLeftX,
              cachedNotchRect.origin.x, cachedNotchRect.origin.y,
              cachedNotchRect.width, cachedNotchRect.height)
    }

    // MARK: - Hidden Items

    /// Items to the left of the separator, filtered to the separator's display.
    private func itemsLeftOfSeparator() -> [MenuBarItem] {
        let sepX = separatorOriginX

        // Use CGDisplayBounds (Quartz coords, same as CGWindowList) to
        // restrict items to the display the separator is actually on.
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
    private var hiddenItemCount: Int {
        let live = cachedHiddenItemInfo.count
        return live > 0 ? live : postCollapseItemCount
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

        snugLog(" collapseMenuBar: isCollapsed=%d, hasNotch=%d, cachedNaturalPositions=%d, cachedHiddenItems=%d, cachedHiddenItemInfo=%d",
              isCollapsed ? 1 : 0, hasNotch ? 1 : 0,
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
            updateNotchDropdownItems()
            snugLog(" collapseMenuBar: resolved %d item names: %@",
                  cachedHiddenItemInfo.count,
                  cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))
        }

        isCollapsed = true
        updateToggleIcon()

        autoHideTimer?.invalidate()
        autoHideTimer = nil

        // Recalculate in case screen changed or initial value was stale.
        updateCollapseLength()
        separatorItem.length = collapseLength
        if notchDropdownCoordinator == nil {
            setupNotchDropdown()
        }
        notchDropdownCoordinator?.update(items: cachedHiddenItemInfo, notchRect: cachedNotchRect)
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
    private func postCollapseDiscovery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isCollapsed else { return }

            self.itemManager.refreshItems()
            let allPushed = self.allItemsPushedBySeparator()

            snugLog(" postCollapseDiscovery: allPushed=%d, previous postCollapseItemCount=%d, cachedHiddenItems=%d",
                  allPushed.count, self.postCollapseItemCount, self.cachedHiddenItems.count)
            for item in allPushed {
                snugLog("   pushed item: wid=%d owner=%@ pid=%d x=%.0f",
                      item.windowID, item.ownerName, item.ownerPID, item.frame.origin.x)
            }

            if allPushed.count != self.postCollapseItemCount {
                self.postCollapseItemCount = allPushed.count
                snugLog(" postCollapseDiscovery: count changed to %d", allPushed.count)
            }

            // Find items discovered post-collapse that weren't in the natural-width scan.
            let knownIDs = Set(self.cachedHiddenItems.map { $0.windowID })
            let newItems = allPushed.filter { !knownIDs.contains($0.windowID) }

            snugLog(" postCollapseDiscovery: knownIDs=%d, newItems=%d",
                  knownIDs.count, newItems.count)

            if !newItems.isEmpty {
                let newInfo = Self.resolveItemsByProcess(newItems)
                snugLog(" postCollapseDiscovery: resolved %d new items by process: %@",
                      newInfo.count, newInfo.map { $0.name }.joined(separator: ", "))
                let existingNames = Set(self.cachedHiddenItemInfo.map { self.baseName(of: $0.name) })
                snugLog(" postCollapseDiscovery: existing names: %@",
                      existingNames.sorted().joined(separator: ", "))
                let uniqueNew = newInfo.filter { !existingNames.contains(self.baseName(of: $0.name)) }
                snugLog(" postCollapseDiscovery: uniqueNew from process=%d", uniqueNew.count)
                if !uniqueNew.isEmpty {
                    self.cachedHiddenItemInfo.append(contentsOf: uniqueNew)
                    self.cachedHiddenItemInfo.sort { $0.name < $1.name }
                    self.updateNotchDropdownItems()
                }
            }

            // Also try AX tree enumeration to discover items that process-based
            // resolution misses (e.g., Control Centre-hosted third-party items).
            // Use the toggle position as the dividing line — everything to its left is "hidden".
            let toggleX = self.toggleItem.button?.window?.frame.origin.x ?? CGFloat.greatestFiniteMagnitude
            let screenY = self.toggleItem.button?.window?.frame.midY ?? 12
            let axExtras = AccessibilityMenuBarHelper.enumerateAllExtras(leftOf: toggleX, screenY: screenY)
            if !axExtras.isEmpty {
                let existingNamesNow = Set(self.cachedHiddenItemInfo.map { self.baseName(of: $0.name) })
                let newFromAX = axExtras.filter { !existingNamesNow.contains(self.baseName(of: $0.name)) }
                if !newFromAX.isEmpty {
                    snugLog(" postCollapseDiscovery: AX enumeration found %d additional items: %@",
                          newFromAX.count, newFromAX.map { $0.name }.joined(separator: ", "))
                    self.cachedHiddenItemInfo.append(contentsOf: newFromAX)
                    self.cachedHiddenItemInfo.sort { $0.name < $1.name }
                    self.updateNotchDropdownItems()
                }
            }

            snugLog(" postCollapseDiscovery DONE: cachedHiddenItemInfo=%d, postCollapseItemCount=%d: %@",
                  self.cachedHiddenItemInfo.count, self.postCollapseItemCount,
                  self.cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))

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
        notchDropdownCoordinator?.stop()
        notchDropdownCoordinator = nil

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

        let freshInfo = AccessibilityMenuBarHelper.resolveItems(for: hidden)
        if postCollapseItemCount > freshInfo.count &&
           cachedHiddenItemInfo.count > freshInfo.count {
            let freshNames = Set(freshInfo.map { baseName(of: $0.name) })
            let preserved = cachedHiddenItemInfo.filter {
                !freshNames.contains(baseName(of: $0.name))
            }
            cachedHiddenItemInfo = freshInfo + preserved
            cachedHiddenItemInfo.sort { $0.name < $1.name }
        } else {
            cachedHiddenItemInfo = freshInfo
        }
        updateNotchDropdownItems()
        snugLog(" refreshHiddenItemCache: hidden=%d, resolved=%d",
              hidden.count, cachedHiddenItemInfo.count)
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
        notchDropdownCoordinator?.dismissPanel()

        let menu = NSMenu()

        // Show all hidden items when collapsed
        let allItems = isCollapsed ? cachedHiddenItemInfo : []

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
        notchDropdownCoordinator?.stop()
        notchDropdownCoordinator = nil

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

        // Re-evaluate pocket state when toggled
        setupNotchDropdown()
    }

    // MARK: - Screen Changes

    @objc private func handleWakeFromSleep() {
        guard isCollapsed else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.isCollapsed else { return }

            snugLog(" handleWakeFromSleep: expanding")
            self.isCollapsed = false
            self.updateToggleIcon()
            self.separatorItem.length = NSStatusItem.variableLength
            self.cachedNaturalPositions = []
            self.cachedHiddenItems = []
            self.cachedHiddenItemInfo = []

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isCollapsed else { return }

                snugLog(" handleWakeFromSleep: re-collapsing with fresh AX data")
                self.collapseMenuBar()
            }
        }
    }

    @objc private func screenParametersChanged() {
        notchDropdownCoordinator?.dismissPanel()
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        notchDropdownCoordinator?.stop()
        notchDropdownCoordinator = nil
        cachedNaturalPositions = []
        cachedHiddenItems = []
        cachedHiddenItemInfo = []
        cachedNotchRect = .zero
        postCollapseItemCount = 0
        isActivatingItem = false
        calculateSafeLeftX()
        updateCollapseLength()
        setupNotchDropdown()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.isCollapsed {
                self.notchDropdownCoordinator?.update(items: self.cachedHiddenItemInfo, notchRect: self.cachedNotchRect)
                self.postCollapseDiscovery()
            } else {
                self.refreshHiddenItemCache()
            }
        }
    }
}

#if DEBUG
extension StatusBarController {
    struct DebugSnapshot {
        let isCollapsed: Bool
        let separatorLength: CGFloat
        let cachedNaturalPositionsCount: Int
        let cachedHiddenItemsCount: Int
        let cachedHiddenItemInfoCount: Int
        let startupRescanTimerIsActive: Bool
    }

    func debugSnapshot() -> DebugSnapshot {
        DebugSnapshot(
            isCollapsed: isCollapsed,
            separatorLength: separatorItem.length,
            cachedNaturalPositionsCount: cachedNaturalPositions.count,
            cachedHiddenItemsCount: cachedHiddenItems.count,
            cachedHiddenItemInfoCount: cachedHiddenItemInfo.count,
            startupRescanTimerIsActive: startupRescanTimer != nil
        )
    }

    func debugSetCollapsedState(_ collapsed: Bool, separatorLength: CGFloat) {
        isCollapsed = collapsed
        separatorItem.length = separatorLength
        updateToggleIcon()
    }

    func debugPrimeCaches() {
        cachedNaturalPositions = [(windowID: 101, naturalX: 42)]
        cachedHiddenItems = [
            MenuBarItem(
                windowID: 101,
                frame: CGRect(x: 42, y: 0, width: 18, height: 18),
                ownerPID: 123,
                ownerName: "Example",
                bundleID: "com.example.app",
                title: "Example"
            )
        ]
        cachedHiddenItemInfo = [
            HiddenItemInfo(
                name: "Example",
                icon: nil,
                frame: CGRect(x: 42, y: 0, width: 18, height: 18),
                windowID: 101,
                ownerPID: 123
            )
        ]
    }

    func debugInvokeWakeHandler() {
        handleWakeFromSleep()
    }
}
#endif
