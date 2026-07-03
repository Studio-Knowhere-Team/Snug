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

    /// True while `restorePromotedPositions`' synthetic drags are in flight.
    /// Collapse must not proceed mid-drag: auto-hide, the heartbeat, and
    /// screen changes all call `collapseMenuBar` directly, and extending the
    /// separator to collapseLength while an item is being dragged would drop
    /// it at an arbitrary X that macOS then persists. Set before the restore
    /// task starts; cleared just before it re-enters `collapseMenuBar`.
    private var isRestoring = false

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

    // MARK: - Promoted Items
    //
    // When the user clicks a hidden item from the right-click context
    // menu, `activateHiddenItem` Cmd+drags it from its natural-width X
    // (which may be behind the notch, where its menu would otherwise
    // open invisibly) to `separatorX − 10` so the menu opens at a
    // visible position. macOS persists Cmd+drag positions, so without a
    // counter-action the user's bar layout would be permanently changed
    // every time they activate a hidden item.
    //
    // To restore the original layout, we record each promoted item with
    // its pre-drag X and replay a reverse Cmd+drag on the next collapse
    // — *before* the separator extends to push everything off-screen.
    // Auto-collapse provides the trigger for users who have it on; users
    // with auto-collapse off get the restore on their next manual
    // collapse.

    private struct PromotedItem {
        let windowID: CGWindowID
        let originalX: CGFloat
        let menuBarY: CGFloat
    }

    private var promotedItems: [PromotedItem] = []

    /// Width used to push items off-screen (recalculated on screen changes)
    private var collapseLength: CGFloat = 10000

    private(set) var isCollapsed: Bool = false

    // MARK: - Smart Expansion

    /// Whether the natural-width caches (`cachedHiddenItems`,
    /// `cachedHiddenItemInfo`) have been captured since the last event that
    /// could invalidate item positions (startup, screen change). When false,
    /// the next collapse re-captures before extending the separator.
    private var hasCapturedNaturalState = false

    /// Cached hidden items for AX name resolution on right-click
    private var cachedHiddenItems: [MenuBarItem] = []

    /// Pre-resolved info (name + icon) from when items were still visible on screen
    private var cachedHiddenItemInfo: [HiddenItemInfo] = []

    /// Item count discovered post-collapse (includes items behind the notch).
    /// CGWindowList sees all items once they're pushed off-screen, even ones
    /// that were invisible at natural width on a notched display.
    ///
    /// Updated only via the stability gate in `postCollapseDiscovery` —
    /// never from a single transient `allPushedCount` reading. See
    /// `CacheMerge.promoteCountIfStable` for the gate logic.
    private var postCollapseItemCount: Int = 0

    /// Pending post-collapse reading held until confirmed by a second
    /// matching observation. Nil means no pending value. This is the
    /// stability-gate state for `postCollapseItemCount`; see the 6→9 bug
    /// fix at `CacheMerge.promoteCountIfStable`.
    private var pendingCountReading: Int?

    // MARK: - Snapshot
    //
    // Atomic value-type view of the hidden-item state, rebuilt via
    // `synthesizeSnapshot` whenever the cached fields change. Consumers
    // (badge icon, right-click menu) read this instead of the individual
    // cached fields so they can never observe a torn mid-merge state.
    //
    // INVARIANT (see MenuBarSnapshot doc): `totalCount` must reflect a
    // stable reading, never a single transient value. This is upheld by
    // seeding it from `postCollapseItemCount`, which only changes through
    // the `CacheMerge.promoteCountIfStable` gate.

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
            button.image = StatusBarIcon.separator()
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
            button.image = StatusBarIcon.separator()
        }

        // Configure toggle button
        if let button = toggleItem.button {
            button.image = StatusBarIcon.collapsed(count: 0)
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
            self.hasCapturedNaturalState = true
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

    // MARK: - Toggle Icon

    /// Count of hidden items for the badge: the snapshot's stable physical
    /// count. This is always >= `items.count` — when AX has only resolved
    /// names for some of the hidden items (e.g. right after login, or
    /// behind-notch items pre-discovery), the badge still reflects how many
    /// items are physically hidden, not how many we can name.
    ///
    /// Reads through `currentSnapshot` so the badge reflects the atomic
    /// state — no torn read between `items.count` and `totalCount`.
    private var hiddenItemCount: Int {
        currentSnapshot.totalCount
    }

    private func updateToggleIcon(animated: Bool = true) {
        let newImage = isCollapsed
            ? StatusBarIcon.collapsed(count: hiddenItemCount)
            : StatusBarIcon.expanded()

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
        // A restore pass is still dragging items back to their original X —
        // let it finish; it re-enters collapseMenuBar when done. Without
        // this guard, auto-hide / heartbeat / screen-change calls arriving
        // mid-restore would extend the separator while a synthetic drag is
        // in flight, dropping the item at an arbitrary X. The collapse this
        // caller wanted still happens (the restore tail performs it), so the
        // request can be dropped — but release isToggling so the button
        // isn't dead until the deferred collapse clears it.
        guard !isRestoring else {
            isToggling = false
            return
        }

        // If any items were promoted to a visible position by the
        // right-click activate flow, restore them to their original X
        // *before* the separator extends to push everything off-screen.
        // The restore Cmd+drag is async (usleep-driven), so we kick off a
        // task and re-enter `collapseMenuBar` from its tail with the
        // promoted list cleared.
        if !promotedItems.isEmpty {
            let toRestore = promotedItems
            promotedItems = []
            isRestoring = true
            Task { @MainActor [weak self] in
                await self?.restorePromotedPositions(toRestore)
                self?.isRestoring = false
                self?.collapseMenuBar()
            }
            return
        }

        // Safety: if the separator was cmd-dragged to the wrong side, fix it.
        ensureSeparatorIsLeftOfToggle()

        snugLog(" collapseMenuBar: isCollapsed=%d, hasCapturedNaturalState=%d, cachedHiddenItems=%d, cachedHiddenItemInfo=%d",
              isCollapsed ? 1 : 0,
              hasCapturedNaturalState ? 1 : 0, cachedHiddenItems.count, cachedHiddenItemInfo.count)

        // Capture hidden items before collapse (items at natural width).
        if !isCollapsed && !hasCapturedNaturalState {
            itemManager.refreshItems()
            let hidden = itemsLeftOfSeparator()
            hasCapturedNaturalState = true
            cachedHiddenItems = hidden
            snugLog(" collapseMenuBar: captured %d hidden items at natural width", hidden.count)
        }

        // Resolve names while items are still on-screen (AX needs visible positions).
        if !isCollapsed && cachedHiddenItemInfo.isEmpty {
            cachedHiddenItemInfo = AccessibilityMenuBarHelper.resolveItems(for: cachedHiddenItems)
            snugLog(" collapseMenuBar: resolved %d item names: %@",
                  cachedHiddenItemInfo.count,
                  cachedHiddenItemInfo.map { $0.name }.joined(separator: ", "))
        }

        // Capture the snapshot now — items are still at natural width, so
        // names resolved this cycle won't be replaced by a later
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

            // Snapshot the cache names up front so we can detect real changes
            // and only log when something actually moved — avoids spamming the
            // log every startup-rescan tick when nothing has changed.
            let namesBefore = self.cachedHiddenItemInfo.map { $0.name }

            // Stability gate — the heart of the 6→9 fix. A single transient
            // `allPushed.count` (e.g. 12 during a display reconfig that
            // briefly duplicates items) must NOT become the authoritative
            // count. Promote only when we've seen the same value twice in a
            // row. Everything downstream reconciles against the STABLE count.
            let gate = CacheMerge.promoteCountIfStable(
                observed: allPushed.count,
                current: self.postCollapseItemCount,
                pending: self.pendingCountReading
            )
            if gate.newCount != self.postCollapseItemCount {
                snugLog(" postCollapseDiscovery: count %d → %d (stabilized)",
                      self.postCollapseItemCount, gate.newCount)
                self.postCollapseItemCount = gate.newCount
            }
            self.pendingCountReading = gate.newPending
            let stableCount = self.postCollapseItemCount

            // Resolve items discovered post-collapse that weren't in the
            // natural-width scan (typically behind-notch items whose windows
            // only become enumerable once pushed off-screen).
            let knownIDs = Set(self.cachedHiddenItems.map { $0.windowID })
            let newItems = allPushed.filter { !knownIDs.contains($0.windowID) }
            let newInfo = newItems.isEmpty ? [] : Self.resolveItemsByProcess(newItems)

            let isAppRunning: (pid_t) -> Bool = {
                NSRunningApplication(processIdentifier: $0) != nil
            }

            // Reconcile: prune quit apps, merge CGWindowList-sourced items,
            // trim any overshoot past the stable count.
            var merged = CacheMerge.applyPostCollapseDiscovery(
                cache: self.cachedHiddenItemInfo,
                stableCount: stableCount,
                newItemsByProcess: newInfo,
                perAppResolved: [],
                isAppRunning: isAppRunning
            )

            // Walk every running app and ask it directly for its own
            // AXExtrasMenuBar — but ONLY if we're still missing names for
            // hidden items. This is the only path that can name
            // behind-the-notch items on a notched MBP (CGWindowList reports
            // their owner as Control Centre, which we skip). The per-app
            // scan is flaky, though: during display transitions or while a
            // status item is being realized it will briefly return apps
            // whose extras are actually *visible* on the right of the
            // separator, with zero AX frames. Gating it on the gap to the
            // STABLE count means we don't add phantoms when the cache is
            // already complete: during a transient, the stable count hasn't
            // moved, so the gap is 0 and the scan isn't consulted.
            let gap = max(0, stableCount - merged.count)
            if gap > 0 {
                let toggleX = self.toggleItem.button?.window?.frame.origin.x
                    ?? CGFloat.greatestFiniteMagnitude
                let byApp = await AccessibilityMenuBarHelper
                    .enumerateExtrasByRunningApps(leftOf: toggleX)
                // The user may have expanded while the scan was running —
                // its results describe a collapsed bar that no longer exists.
                guard self.isCollapsed else { return }
                merged = CacheMerge.applyPostCollapseDiscovery(
                    cache: merged,
                    stableCount: stableCount,
                    newItemsByProcess: [],
                    perAppResolved: byApp,
                    isAppRunning: isAppRunning
                )
            }

            self.cachedHiddenItemInfo = merged

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
        let entries: [HiddenItemInfo] = items.compactMap { item in
            let app = NSRunningApplication(processIdentifier: item.ownerPID)
            let name = app?.localizedName ?? item.ownerName
            guard !name.isEmpty else { return nil }
            // Skip Control Centre — it hosts third-party items on modern macOS,
            // so grouping by its name is meaningless.
            guard !CacheMerge.isControlCentre(name) else { return nil }
            // Skip Window Server — it briefly owns phantom duplicate status-item
            // windows during Control Centre replication events (visible in
            // CGWindowList but not real, user-facing menu bar extras).
            guard name != "Window Server" else { return nil }
            // Skip system widgets
            guard !AccessibilityMenuBarHelper.systemWidgetNames.contains(name) else { return nil }

            return HiddenItemInfo(
                name: name,
                icon: app?.icon?.scaled(to: NSSize(width: 16, height: 16)),
                frame: item.frame,
                windowID: item.windowID,
                ownerPID: item.ownerPID
            )
        }
        return CacheMerge.dedupeByName(entries)
    }

    private func expandMenuBar() {
        // Safety: if the separator was cmd-dragged to the wrong side, fix it.
        ensureSeparatorIsLeftOfToggle()

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
    ///
    /// Merges fresh discovery with the existing cache, capped at the
    /// authoritative count (max of `hidden.count` and the last stable
    /// post-collapse count). Fresh discovery at expanded width can miss
    /// items that only become visible post-collapse (behind the notch),
    /// so prior entries are preserved to fill that gap — but never beyond
    /// the true count. See `CacheMerge.applyRefreshAfterExpand` for the
    /// merge rules.
    private func refreshHiddenItemCache() {
        itemManager.refreshItems()
        let hidden = itemsLeftOfSeparator()
        hasCapturedNaturalState = true
        cachedHiddenItems = hidden

        let freshInfo = AccessibilityMenuBarHelper.resolveItems(for: hidden)
        let countBefore = cachedHiddenItemInfo.count
        cachedHiddenItemInfo = CacheMerge.applyRefreshAfterExpand(
            cache: cachedHiddenItemInfo,
            freshInfo: freshInfo,
            hiddenCount: hidden.count,
            postCollapseItemCount: postCollapseItemCount,
            isAppRunning: { NSRunningApplication(processIdentifier: $0) != nil }
        )
        // Only log when the cache count actually moved — steady-state
        // expand/collapse cycles on an unchanged menu bar stay silent.
        if cachedHiddenItemInfo.count != countBefore {
            snugLog(" refreshHiddenItemCache: %d → %d items (hidden=%d)",
                  countBefore, cachedHiddenItemInfo.count, hidden.count)
        }

        synthesizeSnapshot(width: .natural)
    }

    /// Rebuild `currentSnapshot` from the cached fields. Must be called by
    /// every site that mutates `cachedHiddenItemInfo` or
    /// `postCollapseItemCount` so snapshot readers (badge, right-click
    /// menu) stay consistent with the caches.
    private func synthesizeSnapshot(width: MenuBarSnapshot.Width) {
        currentSnapshot = MenuBarSnapshot(
            items: cachedHiddenItemInfo,
            totalCount: max(cachedHiddenItemInfo.count, postCollapseItemCount),
            capturedAt: Date(),
            capturedWidth: width
        )
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

    /// Open a hidden item's own menu by expanding the bar, dragging the
    /// item next to the separator (if needed), and `AXPress`ing it.
    ///
    /// Rewritten in Step 7 from nested `DispatchQueue.asyncAfter` callbacks
    /// with hard-coded 400 ms and 300 ms delays to structured concurrency
    /// with polling waits and a 3-attempt `AXPress` retry. The old hard-
    /// coded delays caused the `AXPress result=-25204` (stale element)
    /// failures seen in production logs on Flux: the press fired before
    /// the AX tree had caught up with the post-drag window position.
    func activateHiddenItem(_ info: HiddenItemInfo) {
        guard !isActivatingItem else { return }
        isActivatingItem = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isActivatingItem = false
                self.autoCollapseIfNeeded()
            }

            snugLog(" activateHiddenItem: '%@' ownerPID=%d", info.name, info.ownerPID)

            // Expand to natural width — items must be on-screen for Cmd+drag.
            self.separatorItem.length = NSStatusItem.variableLength
            self.isCollapsed = false
            self.updateToggleIcon()

            // Wait for the item's natural-width X to settle (two consecutive
            // reads within 1 px, up to 600 ms). Replaces the old blind 400 ms
            // delay — some apps reach their natural position in ~100 ms on
            // fast hardware, while slower apps took longer than 400 ms and
            // caused stale-element press failures.
            await self.pollUntilStable(windowID: info.windowID, timeoutMillis: 600)

            self.itemManager.refreshItems()
            let freshFrame = self.itemManager.items
                .first(where: { $0.windowID == info.windowID })?.frame ?? info.frame

            let sepX = self.separatorOriginX
            let targetX = sepX - 10
            let menuBarY = freshFrame.midY

            snugLog(" activateHiddenItem: item at x=%.0f, separator at x=%.0f, target x=%.0f",
                  freshFrame.midX, sepX, targetX)

            if abs(freshFrame.midX - targetX) > 30 {
                // Remember where this item *was* so the next collapse can
                // restore it. Skip when windowID is 0 (per-app-resolved
                // behind-notch entries — we can't track them via
                // CGWindowList) and when the same windowID is already
                // promoted (a re-activation before any collapse should not
                // overwrite the true original X with the post-drag X).
                if info.windowID != 0,
                   !self.promotedItems.contains(where: { $0.windowID == info.windowID }) {
                    self.promotedItems.append(PromotedItem(
                        windowID: info.windowID,
                        originalX: freshFrame.midX,
                        menuBarY: menuBarY
                    ))
                }

                // Run the Cmd+drag (which uses usleep internally) on a
                // background task so the main actor isn't blocked.
                let moved = await Task.detached(priority: .userInitiated) {
                    AccessibilityMenuBarHelper.moveItem(
                        from: freshFrame.midX,
                        to: targetX,
                        menuBarY: menuBarY
                    )
                }.value
                snugLog(" activateHiddenItem: moveItem=%d", moved ? 1 : 0)

                // Wait for the item to arrive at targetX (±5 px), up to
                // 600 ms. Replaces the old blind 300 ms delay; on Flux,
                // which triggered the -25204 failure, the item occasionally
                // needed >300 ms to settle after the drag.
                await self.pollUntilNear(
                    windowID: info.windowID,
                    targetX: targetX,
                    toleranceX: 5,
                    timeoutMillis: 600
                )
            }

            // Re-resolve frame once more so `pressItem`'s position fallback
            // uses the post-drag location.
            self.itemManager.refreshItems()
            let pressFrame = self.itemManager.items
                .first(where: { $0.windowID == info.windowID })?.frame ?? freshFrame

            // Press with retry. `AXUIElementPerformAction` returns
            // kAXErrorInvalidUIElement (-25204) when the element has been
            // invalidated mid-scene (a common outcome of Control Centre's
            // replicant re-creation after our drag). Retrying gives the
            // AX tree a chance to catch up; findExtraByPID is re-run
            // inside pressItem each attempt.
            var pressed = false
            for attempt in 0..<3 {
                pressed = AccessibilityMenuBarHelper.pressItem(
                    named: info.name,
                    ownerPID: info.ownerPID,
                    fallbackFrame: pressFrame
                )
                if pressed { break }
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            if !pressed {
                snugLog(" activateHiddenItem: AXPress failed after 3 attempts for '%@'",
                      info.name)
            }
        }
    }

    /// Poll `itemManager` every 50 ms until the given window's X position
    /// is the same for two consecutive reads (within 1 px), or the timeout
    /// elapses. Returns early once stable — doesn't burn the full budget
    /// when the item has already settled.
    private func pollUntilStable(windowID: CGWindowID, timeoutMillis: Int) async {
        let steps = max(1, timeoutMillis / 50)
        var lastX: CGFloat? = nil
        var stableReads = 0
        for _ in 0..<steps {
            try? await Task.sleep(for: .milliseconds(50))
            itemManager.refreshItems()
            let currentX = itemManager.items
                .first(where: { $0.windowID == windowID })?.frame.midX
            if let currentX, let last = lastX, abs(currentX - last) < 1 {
                stableReads += 1
                if stableReads >= 2 { return }
            } else {
                stableReads = 0
            }
            lastX = currentX
        }
    }

    /// Cmd+drag each previously-promoted item back to the X it was at
    /// before `activateHiddenItem` moved it next to the separator.
    /// Called from the top of `collapseMenuBar` so the restore happens
    /// *before* the separator extends and pushes everything off-screen.
    ///
    /// Skips entries whose item is no longer in `itemManager.items`
    /// (the owning app may have quit while its menu was open) and
    /// entries whose current X is already within 5 px of the target
    /// (no-op drags risk macOS's input system rejecting them).
    private func restorePromotedPositions(_ items: [PromotedItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            itemManager.refreshItems()
            guard let current = itemManager.items
                .first(where: { $0.windowID == item.windowID }) else {
                continue
            }
            let currentX = current.frame.midX
            if abs(currentX - item.originalX) < 5 { continue }

            snugLog(" restorePromoted: wid=%d %.0f → %.0f",
                  item.windowID, currentX, item.originalX)

            await Task.detached(priority: .userInitiated) {
                _ = AccessibilityMenuBarHelper.moveItem(
                    from: currentX,
                    to: item.originalX,
                    menuBarY: item.menuBarY
                )
            }.value
        }
    }

    /// Poll `itemManager` every 50 ms until the given window's X position
    /// is within `toleranceX` of `targetX`, or the timeout elapses.
    private func pollUntilNear(
        windowID: CGWindowID,
        targetX: CGFloat,
        toleranceX: CGFloat,
        timeoutMillis: Int
    ) async {
        let steps = max(1, timeoutMillis / 50)
        for _ in 0..<steps {
            try? await Task.sleep(for: .milliseconds(50))
            itemManager.refreshItems()
            if let currentX = itemManager.items
                .first(where: { $0.windowID == windowID })?.frame.midX,
               abs(currentX - targetX) < toleranceX {
                return
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
        // Positions can still be stale, so force a re-capture on next collapse.
        hasCapturedNaturalState = false
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
