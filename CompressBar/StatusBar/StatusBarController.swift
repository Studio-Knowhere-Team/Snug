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
    private var isToggling = false

    /// Width used to push items off-screen (recalculated on screen changes)
    private var collapseLength: CGFloat = 4000

    private(set) var isCollapsed: Bool = false

    // MARK: - Smart Expansion

    /// Natural positions of hidden items captured from fully-expanded state
    private var cachedNaturalPositions: [(windowID: CGWindowID, naturalX: CGFloat)] = []

    /// Cached hidden items for AX name resolution on right-click
    private var cachedHiddenItems: [MenuBarItem] = []

    /// Pre-resolved info (name + icon) from when items were still visible on screen
    private var cachedHiddenItemInfo: [HiddenItemInfo] = []

    /// Timer that polls AX to detect when an opened status menu closes
    private var menuPollTimer: Timer?

    /// The frame of the item whose menu we opened (for polling AX)
    private var openedMenuItemFrame: CGRect?

    /// The name of the item whose menu we opened (for name-based polling
    /// when position-based isMenuOpen fails, e.g. behind-notch items)
    private var openedMenuItemName: String?

    /// Number of items that couldn't fit in the safe area (behind notch)
    private var overflowCount: Int = 0

    /// Resolved info for items stuck behind the notch during smart expansion
    private var cachedOverflowItemInfo: [HiddenItemInfo] = []

    /// Whether the current display has a notch
    private var hasNotch: Bool = false

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

    init(preferences: AppPreferences = .shared) {
        self.preferences = preferences

        // Creation order determines initial position (rightmost first).
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()
        setup()
    }

    private func setup() {
        calculateSafeLeftX()
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.registerOwnWindowIDs()
            self?.collapseMenuBar()
        }
    }

    // MARK: - Icons

    private static let circleR: CGFloat = 6
    private static let circleCY: CGFloat = 9
    private static let iconLW: CGFloat = 1.5

    /// Left half-circle  (
    private static func makeSeparatorIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 9, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()

        let path = NSBezierPath()
        path.lineWidth = iconLW
        path.lineCapStyle = .round
        path.appendArc(withCenter: NSPoint(x: 7, y: circleCY),
                       radius: circleR,
                       startAngle: 90, endAngle: 270)
        path.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Full outlined circle  ○
    private static func makeExpandedIcon() -> NSImage {
        let d = circleR * 2
        let w = d + 4
        let cx = w / 2
        let image = NSImage(size: NSSize(width: w, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()

        let path = NSBezierPath(ovalIn: NSRect(x: cx - circleR, y: circleCY - circleR,
                                                width: d, height: d))
        path.lineWidth = iconLW
        path.stroke()

        image.unlockFocus()
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

            let image = NSImage(size: NSSize(width: w, height: h))
            image.lockFocus()

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

            image.unlockFocus()
            image.isTemplate = true
            return image
        }

        let r: CGFloat = 8                          // filled circle radius (original size)
        let arcHR: CGFloat = 3                       // horizontal radius (narrow)
        let arcVR = r - 2                            // vertical radius matches filled circle
        let arcCX = pad + arcHR                      // arc center X
        let filledCX = arcCX + gap + r               // filled circle center
        let w = filledCX + r + pad                   // total image width

        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()

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

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Notch Detection

    private func calculateSafeLeftX() {
        hasNotch = NSStatusBar.system.thickness > 30

        if hasNotch {
            // Use the menu bar screen (primary display), not NSScreen.main
            // which follows keyboard focus and may be a non-notched external.
            let screen = toggleItem.button?.window?.screen ?? NSScreen.screens.first
            safeLeftX = (screen?.frame.width ?? 1728) / 2 + 120
        } else {
            safeLeftX = 80
        }
        snugLog(" calculateSafeLeftX: hasNotch=%d, safeLeftX=%.0f, thickness=%.0f",
              hasNotch ? 1 : 0, safeLeftX, NSStatusBar.system.thickness)
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
    private func discoverNaturalPositions(completion: @escaping () -> Void) {
        separatorItem.length = NSStatusItem.variableLength

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }

            self.itemManager.refreshItems()

            let hidden = self.itemsLeftOfSeparator()
            self.cachedNaturalPositions = hidden
                .map { (windowID: $0.windowID, naturalX: $0.frame.minX) }
            self.cachedHiddenItems = hidden

            snugLog(" discoverNaturalPositions: hidden=%d, hasNotch=%d, previous cachedHiddenItemInfo=%d",
                  hidden.count, self.hasNotch ? 1 : 0, self.cachedHiddenItemInfo.count)
            snugLog(" discoverNaturalPositions: previous items: %@",
                  self.cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))

            // Resolve names/icons for items visible at natural width.
            let freshInfo = AccessibilityMenuBarHelper.resolveItems(for: hidden)

            snugLog(" discoverNaturalPositions: AX resolved %d of %d: %@",
                  freshInfo.count, hidden.count,
                  freshInfo.map { $0.name }.joined(separator: ", "))

            // Some items may be invisible at natural width (behind the notch, or
            // macOS hides them from both CGWindowList and AX). These were discovered
            // post-collapse and added to cachedHiddenItemInfo. Preserve those entries
            // so the right-click menu stays complete.
            // Use postCollapseItemCount as ground truth — it's from CGWindowList after
            // collapse when ALL items are visible (pushed off-screen).
            if self.postCollapseItemCount > freshInfo.count &&
               self.cachedHiddenItemInfo.count > freshInfo.count {
                let freshNames = Set(freshInfo.map { self.baseName(of: $0.name) })
                let preserved = self.cachedHiddenItemInfo.filter {
                    !freshNames.contains(self.baseName(of: $0.name))
                }
                self.cachedHiddenItemInfo = freshInfo + preserved
                self.cachedHiddenItemInfo.sort { $0.name < $1.name }
                snugLog(" discoverNaturalPositions: PRESERVED %d items (fresh=%d, postCollapse=%d, total=%d): %@",
                      preserved.count, freshInfo.count, self.postCollapseItemCount,
                      self.cachedHiddenItemInfo.count,
                      self.cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))
            } else {
                self.cachedHiddenItemInfo = freshInfo
                snugLog(" discoverNaturalPositions: NO preserve (postCollapse=%d, old=%d, fresh=%d)",
                      self.postCollapseItemCount, self.cachedHiddenItemInfo.count, freshInfo.count)
            }

            completion()
        }
    }

    /// Strip " (N)" suffix from display name for comparison.
    private func baseName(of displayName: String) -> String {
        if let range = displayName.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            return String(displayName[..<range.lowerBound])
        }
        return displayName
    }

    private func applySmartExpansion() {
        let targetLength: CGFloat

        if !hasNotch {
            targetLength = NSStatusItem.variableLength
            overflowCount = 0
            cachedOverflowItemInfo = []
        } else {
            let sorted = cachedNaturalPositions.sorted { $0.naturalX > $1.naturalX }
            let fitting = sorted.filter { $0.naturalX >= safeLeftX }

            // Overflow = total hidden items minus what fits before the notch.
            // hiddenItemCount includes post-collapse discovered items
            // that CGWindowList missed at natural width (behind the notch).
            let fittingCount = fitting.count
            overflowCount = max(0, hiddenItemCount - fittingCount)

            // Build overflow list: items whose names aren't in the fitting set
            if overflowCount > 0 {
                let fittingIDs = Set(fitting.map { $0.windowID })
                let fittingItems = cachedHiddenItems.filter { fittingIDs.contains($0.windowID) }
                let fittingNames = Set(
                    AccessibilityMenuBarHelper.resolveItems(for: fittingItems)
                        .map { baseName(of: $0.name) }
                )
                cachedOverflowItemInfo = cachedHiddenItemInfo.filter {
                    !fittingNames.contains(baseName(of: $0.name))
                }
            } else {
                cachedOverflowItemInfo = []
            }

            if fitting.isEmpty {
                targetLength = NSStatusItem.variableLength
            } else {
                let leftmostFitting = fitting.last!
                let extra = max(0, leftmostFitting.naturalX - safeLeftX)
                targetLength = 9 + extra
            }
        }

        isCollapsed = false
        updateToggleIcon()

        separatorItem.length = targetLength
        autoCollapseIfNeeded()
    }

    // MARK: - Toggle Icon

    /// Best-effort count of hidden third-party items.
    /// Uses the maximum of all available counts:
    ///   - AX-resolved info (names verified as AXMenuExtra)
    ///   - Post-collapse CGWindowList (sees ALL items including behind-notch)
    ///   - Natural-position CGWindowList minus 1 (fallback heuristic)
    private var hiddenItemCount: Int {
        let axCount = cachedHiddenItemInfo.count
        let postCount = postCollapseItemCount
        let naturalCount = max(cachedNaturalPositions.count - 1, 0)
        return max(axCount, postCount, naturalCount)
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
            snugLog(" collapseMenuBar: resolved %d item names: %@",
                  cachedHiddenItemInfo.count,
                  cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))
        }

        isCollapsed = true
        updateToggleIcon()

        autoHideTimer?.invalidate()
        autoHideTimer = nil

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

            var countChanged = false
            if allPushed.count != self.postCollapseItemCount {
                self.postCollapseItemCount = allPushed.count
                countChanged = true
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
                }
            }

            snugLog(" postCollapseDiscovery DONE: cachedHiddenItemInfo=%d, postCollapseItemCount=%d: %@",
                  self.cachedHiddenItemInfo.count, self.postCollapseItemCount,
                  self.cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))

            if countChanged {
                self.updateToggleIcon()
            }
        }
    }

    /// Resolve hidden item info using process metadata (for items not resolvable via AX position).
    /// Used for behind-notch items that are only discoverable post-collapse via CGWindowList.
    private static func resolveItemsByProcess(_ items: [MenuBarItem]) -> [HiddenItemInfo] {
        var seen: [String: (icon: NSImage?, frame: CGRect)] = [:]
        var counts: [String: Int] = [:]

        for item in items {
            let app = NSRunningApplication(processIdentifier: item.ownerPID)
            let name = app?.localizedName ?? item.ownerName
            guard !name.isEmpty else { continue }
            // Skip Control Centre — it hosts third-party items on modern macOS,
            // so grouping by its name is meaningless.
            guard name != "Control Centre" && name != "Control Center" else { continue }

            counts[name, default: 0] += 1
            if seen[name] == nil {
                let icon: NSImage? = {
                    guard let appIcon = app?.icon else { return nil }
                    let size = NSSize(width: 16, height: 16)
                    let scaled = NSImage(size: size)
                    scaled.lockFocus()
                    appIcon.draw(in: NSRect(origin: .zero, size: size))
                    scaled.unlockFocus()
                    return scaled
                }()
                seen[name] = (icon: icon, frame: item.frame)
            }
        }

        return counts.sorted(by: { $0.key < $1.key }).map { name, count in
            let displayName = count > 1 ? "\(name) (\(count))" : name
            let data = seen[name]!
            return HiddenItemInfo(name: displayName, icon: data.icon, frame: data.frame)
        }
    }

    private func expandMenuBar() {
        // Safety: if the separator was cmd-dragged to the wrong side, fix it.
        ensureSeparatorIsLeftOfToggle()

        snugLog(" expandMenuBar: cachedHiddenItemInfo=%d before discoverNaturalPositions",
              cachedHiddenItemInfo.count)

        // Always rediscover natural positions on every expand.
        // This ensures accuracy if apps launched/quit while collapsed.
        discoverNaturalPositions { [weak self] in
            guard let self else { return }
            snugLog(" expandMenuBar: cachedHiddenItemInfo=%d after discoverNaturalPositions",
                  self.cachedHiddenItemInfo.count)
            self.applySmartExpansion()
            self.isToggling = false
        }
    }

    private func forceFullExpand() {
        separatorItem.length = NSStatusItem.variableLength
        isCollapsed = false
        overflowCount = 0
        cachedOverflowItemInfo = []
        updateToggleIcon()
        autoCollapseIfNeeded()
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
        let screenWidth = NSScreen.main?.frame.width ?? 1728
        let newLength = min(max(screenWidth + 200, 500), 4000)

        let wasCollapsed = isCollapsed
        collapseLength = newLength

        if wasCollapsed {
            separatorItem.length = collapseLength
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        snugLog(" buildContextMenu: isCollapsed=%d, hiddenItemCount=%d, cachedHiddenItemInfo=%d, postCollapseItemCount=%d",
              isCollapsed ? 1 : 0, hiddenItemCount, cachedHiddenItemInfo.count, postCollapseItemCount)
        snugLog(" buildContextMenu: items: %@",
              cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))

        if isCollapsed {
            let count = hiddenItemCount
            let items = cachedHiddenItemInfo

            if !items.isEmpty {
                let header = NSMenuItem(title: "Hidden Items", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)

                for info in items {
                    let menuItem = NSMenuItem(
                        title: info.name,
                        action: #selector(hiddenItemClicked(_:)),
                        keyEquivalent: ""
                    )
                    menuItem.target = self
                    menuItem.image = info.icon
                    menuItem.representedObject = NSValue(rect: NSRect(
                        x: info.frame.origin.x, y: info.frame.origin.y,
                        width: info.frame.size.width, height: info.frame.size.height
                    ))
                    menu.addItem(menuItem)
                }
            } else if count > 0 {
                let label = NSMenuItem(title: "\(count) items hidden", action: nil, keyEquivalent: "")
                label.isEnabled = false
                menu.addItem(label)
            }

            if !items.isEmpty || count > 0 {
                menu.addItem(NSMenuItem.separator())
            }
        }

        if hasNotch && !isCollapsed && overflowCount > 0 {
            if !cachedOverflowItemInfo.isEmpty {
                let header = NSMenuItem(title: "Behind Notch", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)

                for info in cachedOverflowItemInfo {
                    let menuItem = NSMenuItem(
                        title: info.name,
                        action: #selector(hiddenItemClicked(_:)),
                        keyEquivalent: ""
                    )
                    menuItem.target = self
                    menuItem.image = info.icon
                    menuItem.representedObject = NSValue(rect: NSRect(
                        x: info.frame.origin.x, y: info.frame.origin.y,
                        width: info.frame.size.width, height: info.frame.size.height
                    ))
                    menu.addItem(menuItem)
                }
            } else {
                let label = NSMenuItem(
                    title: "\(overflowCount) behind notch",
                    action: nil, keyEquivalent: ""
                )
                label.isEnabled = false
                menu.addItem(label)
            }

            let showAllItem = NSMenuItem(
                title: "Show All",
                action: #selector(forceFullExpandAction),
                keyEquivalent: ""
            )
            showAllItem.target = self
            menu.addItem(showAllItem)
            menu.addItem(NSMenuItem.separator())
        }

        let prefsItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let autoCollapseItem = NSMenuItem(
            title: "Auto-collapse",
            action: #selector(toggleAutoCollapse),
            keyEquivalent: ""
        )
        autoCollapseItem.target = self
        autoCollapseItem.state = preferences.isAutoHide ? .on : .off
        menu.addItem(autoCollapseItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Snug",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        return menu
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
        let menu = buildContextMenu()
        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.toggleItem.menu = nil
        }
    }

    @objc private func hiddenItemClicked(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSValue else {
            snugLog("hiddenItemClicked: no representedObject on menu item '%@'", sender.title)
            return
        }
        let naturalFrame = value.rectValue
        let itemName = sender.title

        snugLog("========== hiddenItemClicked START ==========")
        snugLog("  itemName='%@' naturalFrame=(%.0f,%.0f,%.0f,%.0f)",
              itemName, naturalFrame.origin.x, naturalFrame.origin.y,
              naturalFrame.size.width, naturalFrame.size.height)
        snugLog("  cachedHiddenItems count=%d, cachedNaturalPositions count=%d",
              cachedHiddenItems.count, cachedNaturalPositions.count)

        // Try partial expansion first (better UX — only reveals the target item).
        // This works for items with known windowIDs and valid natural positions.
        let matchedItem = findHiddenItem(matching: naturalFrame)
        snugLog("  findHiddenItem result: %@", matchedItem != nil ? "wid=\(matchedItem!.windowID)" : "nil")

        if let matchedItem,
           let naturalEntry = cachedNaturalPositions.first(where: { $0.windowID == matchedItem.windowID }),
           let partialLength = partialSeparatorLength(for: naturalEntry.naturalX,
                                                       clickedWindowID: matchedItem.windowID) {

            let clickedWindowID = matchedItem.windowID
            snugLog("  PARTIAL expansion: wid=%d, partialLength=%.0f", clickedWindowID, partialLength)
            separatorItem.length = partialLength
            isCollapsed = false
            updateToggleIcon()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.itemManager.refreshItems()

                let pressFrame: CGRect
                if let actual = self.itemManager.items.first(where: { $0.windowID == clickedWindowID }) {
                    pressFrame = actual.frame
                    snugLog("  partial: found actual frame=(%.0f,%.0f,%.0f,%.0f)",
                          pressFrame.origin.x, pressFrame.origin.y, pressFrame.width, pressFrame.height)
                } else {
                    pressFrame = naturalFrame
                    snugLog("  partial: using natural frame (actual not found)")
                }

                if AccessibilityMenuBarHelper.pressItem(at: pressFrame) {
                    snugLog("  partial press SUCCEEDED for '%@'", itemName)
                    self.openedMenuItemFrame = pressFrame
                    self.openedMenuItemName = itemName
                    self.startMenuDismissalPolling()
                } else {
                    snugLog("  partial press FAILED for '%@', falling through to full expansion", itemName)
                    self.fullExpandAndPress(naturalFrame: naturalFrame, itemName: itemName)
                }
            }
        } else {
            // Can't do partial expansion — go straight to full expansion.
            if matchedItem != nil {
                snugLog("  no partial: matchedItem found but naturalEntry or partialLength missing")
            } else {
                snugLog("  no partial: matchedItem not found in cache")
            }
            snugLog("  -> using FULL expansion for '%@'", itemName)
            fullExpandAndPress(naturalFrame: naturalFrame, itemName: itemName)
        }
    }

    /// Full-expansion click with position-based + name-based fallback.
    /// Treats all displays the same — doesn't depend on notch detection.
    private func fullExpandAndPress(naturalFrame: CGRect, itemName: String) {
        snugLog("fullExpandAndPress START: '%@' naturalFrame=(%.0f,%.0f,%.0f,%.0f)",
              itemName, naturalFrame.origin.x, naturalFrame.origin.y,
              naturalFrame.width, naturalFrame.height)
        separatorItem.length = NSStatusItem.variableLength
        isCollapsed = false
        updateToggleIcon()

        let toggleWindow = toggleItem.button?.window
        snugLog("  separator set to variableLength, toggleWindow frame=%@",
              toggleWindow != nil ? "\(toggleWindow!.frame)" : "nil")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.itemManager.refreshItems()
            snugLog("  after 0.3s: refreshed items, count=%d", self.itemManager.items.count)

            // Determine the best known position for this item
            let matchedItem = self.findHiddenItem(matching: naturalFrame)
            snugLog("  findHiddenItem=%@", matchedItem != nil ? "wid=\(matchedItem!.windowID)" : "nil")

            let pressFrame: CGRect
            if let matchedItem,
               let actual = self.itemManager.items.first(where: { $0.windowID == matchedItem.windowID }) {
                pressFrame = actual.frame
                snugLog("  using actual CGWindowList frame=(%.0f,%.0f,%.0f,%.0f)",
                      pressFrame.origin.x, pressFrame.origin.y, pressFrame.width, pressFrame.height)
            } else if naturalFrame.origin.x > 0 {
                pressFrame = naturalFrame
                snugLog("  using naturalFrame (no windowID match)")
            } else {
                snugLog("  no valid position, skipping to name-based press")
                // Jump straight to name-based as last resort
                let screenY = self.toggleItem.button?.window?.frame.midY ?? 12
                if let pressedFrame = AccessibilityMenuBarHelper.pressItemByName(itemName, screenY: screenY) {
                    self.openedMenuItemFrame = pressedFrame
                    self.openedMenuItemName = itemName
                    self.startMenuDismissalPolling()
                    return
                }
                snugLog("  ALL METHODS FAILED for '%@' -> collapsing", itemName)
                self.collapseMenuBar()
                return
            }

            // Step 1: Try AX-based press (works for items that AX can locate by position)
            if AccessibilityMenuBarHelper.pressItem(at: pressFrame) {
                snugLog("  step1: AX press SUCCEEDED for '%@'", itemName)
                self.openedMenuItemFrame = pressFrame
                self.openedMenuItemName = itemName
                self.startMenuDismissalPolling()
                return
            }
            snugLog("  step1: AX press FAILED for '%@'", itemName)

            // Step 2: Direct CGEvent click at the item's known position.
            // This bypasses AX entirely — just sends a mouse click at the coordinates
            // we know from CGWindowList. Works for items on external monitors where the
            // AX tree has stale/wrong data but the item IS at a visible, clickable position.
            let clickPoint = CGPoint(x: pressFrame.midX, y: pressFrame.midY)
            snugLog("  step2: trying CGEvent click at (%.1f, %.1f) for '%@'", clickPoint.x, clickPoint.y, itemName)

            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                       mouseCursorPosition: clickPoint, mouseButton: .left),
               let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                     mouseCursorPosition: clickPoint, mouseButton: .left) {
                mouseDown.post(tap: .cghidEventTap)
                usleep(80_000) // 80ms between down/up
                mouseUp.post(tap: .cghidEventTap)
                snugLog("  step2: CGEvent click SENT for '%@' at (%.1f, %.1f)", itemName, clickPoint.x, clickPoint.y)

                // Give the menu a moment to appear, then verify it opened
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self else { return }

                    // Check if a menu actually opened at this position
                    if AccessibilityMenuBarHelper.isMenuOpen(at: pressFrame) {
                        snugLog("  step2: menu IS open after CGEvent click — success!")
                        self.openedMenuItemFrame = pressFrame
                        self.openedMenuItemName = itemName
                        self.startMenuDismissalPolling()
                        return
                    }

                    snugLog("  step2: menu NOT open after CGEvent click, trying Cmd+drag relocate")

                    // Step 3: Cmd+drag the item to a visible position, then click.
                    // The item might be behind the notch or at a position where clicks
                    // aren't delivered. Move it to a known-good position first.
                    self.cmdDragAndPress(sourceFrame: pressFrame, itemName: itemName)
                }
                return
            }

            snugLog("  step2: CGEvent creation failed, trying Cmd+drag")
            self.cmdDragAndPress(sourceFrame: pressFrame, itemName: itemName)
        }
    }

    // MARK: - Cmd+Drag Relocate and Press

    /// Original position of an item we Cmd+dragged to a new location.
    /// Used to restore the item's position after its menu is dismissed.
    private var relocatedItemSource: CGPoint?

    /// Where we moved the item to (for clicking and restoring).
    private var relocatedItemTarget: CGPoint?

    /// Cmd+drag a menu bar item from its current position to a visible position,
    /// then click it to open its menu. On menu dismissal, the item is moved back.
    private func cmdDragAndPress(sourceFrame: CGRect, itemName: String) {
        // Target position: same Y (same menu bar), X near the separator (visible area).
        // The separator's X in AppKit coords = its Quartz X (only Y differs between systems).
        let separatorX = separatorItem.button?.window?.frame.origin.x ?? 0
        let separatorW = separatorItem.button?.window?.frame.width ?? 10

        // Place target just to the right of the separator (between separator and toggle)
        // Use source Y since it's in Quartz coords (same as CGEvent)
        let targetX = separatorX + separatorW + 20
        let sourcePoint = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)

        // Check if the source and target are on the same screen by comparing Y.
        // If they're on different screens (different Y), the Cmd+drag won't work.
        // In that case, use the source Y for the target too (stay on same menu bar).
        let targetY = sourceFrame.midY  // Same menu bar row

        let targetPoint = CGPoint(x: targetX, y: targetY)

        snugLog("cmdDragAndPress: Cmd+drag '%@' from (%.0f,%.0f) to (%.0f,%.0f)",
              itemName, sourcePoint.x, sourcePoint.y, targetPoint.x, targetPoint.y)

        // Store for restoration on menu dismissal
        relocatedItemSource = sourcePoint
        relocatedItemTarget = targetPoint

        // Simulate Cmd+drag: Cmd+mouseDown → mouseDragged → mouseUp
        let cmdFlags = CGEventFlags.maskCommand

        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                       mouseCursorPosition: sourcePoint, mouseButton: .left) else {
            snugLog("cmdDragAndPress: failed to create mouseDown event")
            collapseMenuBar()
            return
        }
        mouseDown.flags = cmdFlags
        mouseDown.post(tap: .cghidEventTap)

        usleep(150_000) // 150ms hold before drag

        // Drag in a few steps for smoother movement
        let steps = 5
        for i in 1...steps {
            let fraction = CGFloat(i) / CGFloat(steps)
            let intermediateX = sourcePoint.x + (targetPoint.x - sourcePoint.x) * fraction
            let intermediateY = sourcePoint.y + (targetPoint.y - sourcePoint.y) * fraction
            let intermediatePoint = CGPoint(x: intermediateX, y: intermediateY)

            guard let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                      mouseCursorPosition: intermediatePoint, mouseButton: .left) else { continue }
            drag.flags = cmdFlags
            drag.post(tap: .cghidEventTap)
            usleep(30_000) // 30ms between drag steps
        }

        guard let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                     mouseCursorPosition: targetPoint, mouseButton: .left) else {
            snugLog("cmdDragAndPress: failed to create mouseUp event")
            collapseMenuBar()
            return
        }
        mouseUp.post(tap: .cghidEventTap)

        snugLog("cmdDragAndPress: Cmd+drag complete, waiting for settle then clicking")

        // Wait for the item to settle at its new position, then click it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }

            // Click at the target position to open the item's menu
            guard let clickDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                           mouseCursorPosition: targetPoint, mouseButton: .left),
                  let clickUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                         mouseCursorPosition: targetPoint, mouseButton: .left) else {
                snugLog("cmdDragAndPress: failed to create click events")
                self.collapseMenuBar()
                return
            }

            clickDown.post(tap: .cghidEventTap)
            usleep(80_000)
            clickUp.post(tap: .cghidEventTap)

            snugLog("cmdDragAndPress: clicked at target (%.0f,%.0f)", targetPoint.x, targetPoint.y)

            // Use the target position for menu open detection
            let targetFrame = CGRect(x: targetPoint.x - sourceFrame.width / 2,
                                     y: targetPoint.y - sourceFrame.height / 2,
                                     width: sourceFrame.width,
                                     height: sourceFrame.height)
            self.openedMenuItemFrame = targetFrame
            self.openedMenuItemName = itemName
            self.startMenuDismissalPolling()
        }
    }

    /// After a menu closes, if we had Cmd+dragged an item to a new position,
    /// move it back to its original position.
    private func restoreRelocatedItem() {
        guard let source = relocatedItemSource,
              let target = relocatedItemTarget else { return }

        snugLog("restoreRelocatedItem: Cmd+drag back from (%.0f,%.0f) to (%.0f,%.0f)",
              target.x, target.y, source.x, source.y)

        let cmdFlags = CGEventFlags.maskCommand

        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                       mouseCursorPosition: target, mouseButton: .left) else { return }
        mouseDown.flags = cmdFlags
        mouseDown.post(tap: .cghidEventTap)

        usleep(150_000)

        let steps = 5
        for i in 1...steps {
            let fraction = CGFloat(i) / CGFloat(steps)
            let x = target.x + (source.x - target.x) * fraction
            let y = target.y + (source.y - target.y) * fraction

            guard let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                      mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { continue }
            drag.flags = cmdFlags
            drag.post(tap: .cghidEventTap)
            usleep(30_000)
        }

        guard let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                     mouseCursorPosition: source, mouseButton: .left) else { return }
        mouseUp.post(tap: .cghidEventTap)

        relocatedItemSource = nil
        relocatedItemTarget = nil

        snugLog("restoreRelocatedItem: done")
    }

    // MARK: - Partial Expansion Helpers

    /// Find the cachedHiddenItems entry whose natural frame matches the given frame.
    private func findHiddenItem(matching frame: CGRect) -> MenuBarItem? {
        let tolerance: CGFloat = 2.0
        return cachedHiddenItems.first { item in
            abs(item.frame.origin.x - frame.origin.x) < tolerance &&
            abs(item.frame.origin.y - frame.origin.y) < tolerance
        }
    }

    /// Calculate separator length that reveals the clicked item but hides items to its left.
    /// Returns nil if full expansion (variableLength) should be used instead.
    private func partialSeparatorLength(for clickedNaturalX: CGFloat,
                                         clickedWindowID: CGWindowID) -> CGFloat? {
        let naturalSeparatorWidth: CGFloat = 9.0
        let margin: CGFloat = 4.0

        let sorted = cachedNaturalPositions.sorted { $0.naturalX < $1.naturalX }

        guard let clickedIndex = sorted.firstIndex(where: { $0.windowID == clickedWindowID }) else {
            return nil
        }

        // If the clicked item is the leftmost, full expansion is needed
        if clickedIndex == 0 { return nil }

        let leftNeighbor = sorted[clickedIndex - 1]
        let leftNeighborWidth: CGFloat = cachedHiddenItems
            .first(where: { $0.windowID == leftNeighbor.windowID })?
            .frame.width ?? 30

        let leftNeighborRightEdge = leftNeighbor.naturalX + leftNeighborWidth
        let push = leftNeighborRightEdge + margin

        // If push would also hide the clicked item, fall back
        guard push < clickedNaturalX else { return nil }

        let length = naturalSeparatorWidth + push
        guard length > naturalSeparatorWidth, length < collapseLength else { return nil }

        return length
    }


    // MARK: - Menu Dismissal Polling

    private func startMenuDismissalPolling() {
        menuPollTimer?.invalidate()
        snugLog("startMenuDismissalPolling: frame=%@, name=%@",
              openedMenuItemFrame != nil ? "\(openedMenuItemFrame!)" : "nil",
              openedMenuItemName ?? "nil")

        // Small initial delay so the menu has time to appear
        var pollCount = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }

            snugLog("  polling timer starting (0.5s delay passed)")

            self.menuPollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    pollCount += 1

                    // Check if the menu is still open — try position-based first,
                    // fall back to name-based for items behind the notch where
                    // position-based lookup fails.
                    if let frame = self.openedMenuItemFrame {
                        let posOpen = AccessibilityMenuBarHelper.isMenuOpen(at: frame)
                        if pollCount <= 3 {
                            snugLog("  poll[%d]: positionBased isMenuOpen=%d frame=(%.0f,%.0f)",
                                  pollCount, posOpen ? 1 : 0, frame.origin.x, frame.origin.y)
                        }
                        if posOpen { return }
                    }

                    // Position-based check failed — try name-based
                    if let name = self.openedMenuItemName {
                        let screenY = self.toggleItem.button?.window?.frame.midY ?? 12
                        let nameOpen = AccessibilityMenuBarHelper.isMenuOpenByName(name, screenY: screenY)
                        if pollCount <= 3 {
                            snugLog("  poll[%d]: nameBased isMenuOpen=%d name='%@'",
                                  pollCount, nameOpen ? 1 : 0, name)
                        }
                        if nameOpen { return }
                    }

                    // Menu closed — re-collapse
                    snugLog("  poll[%d]: menu CLOSED -> finishMenuDismissal", pollCount)
                    self.finishMenuDismissal()
                }
            }
        }
    }

    private func finishMenuDismissal() {
        snugLog("finishMenuDismissal: relocated=%d", relocatedItemSource != nil ? 1 : 0)
        menuPollTimer?.invalidate()
        menuPollTimer = nil
        openedMenuItemFrame = nil
        openedMenuItemName = nil

        // If we Cmd+dragged an item to a new position, move it back first
        if relocatedItemSource != nil {
            // Small delay so any menu action can complete, then restore + collapse
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.restoreRelocatedItem()
                // Wait for the restore drag to finish before collapsing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.collapseMenuBar()
                }
            }
        } else {
            // Small delay so any menu action can complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.collapseMenuBar()
            }
        }
    }

    @objc private func openPreferences() {
        SettingsOpener.open()
    }

    @objc private func toggleAutoCollapse() {
        preferences.isAutoHide.toggle()
        if preferences.isAutoHide {
            autoCollapseIfNeeded()
        } else {
            autoHideTimer?.invalidate()
            autoHideTimer = nil
        }
    }

    @objc private func forceFullExpandAction() {
        forceFullExpand()
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

    // MARK: - Screen Changes

    @objc private func screenParametersChanged() {
        calculateSafeLeftX()
        updateCollapseLength()
        cachedNaturalPositions = []
        cachedHiddenItems = []
        cachedHiddenItemInfo = []
        cachedOverflowItemInfo = []
        postCollapseItemCount = 0
        menuPollTimer?.invalidate()
        menuPollTimer = nil
        openedMenuItemFrame = nil
        openedMenuItemName = nil
        relocatedItemSource = nil
        relocatedItemTarget = nil
    }
}
