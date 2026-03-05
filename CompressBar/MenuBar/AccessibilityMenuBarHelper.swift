import AppKit
import ApplicationServices

/// Resolved info for a hidden menu bar item.
struct HiddenItemInfo: Sendable {
    let name: String
    let icon: NSImage?
    /// Natural screen position (Quartz coords) for re-querying via AX.
    let frame: CGRect
}

/// Provides optional Accessibility API (AXUIElement) integration for resolving
/// the real names of menu bar status items. On modern macOS, third-party items
/// are hosted by Control Centre, so CGWindowList can't identify them.
/// This helper uses AXUIElementCopyElementAtPosition to query items by their
/// known screen positions and read their accessibility descriptions.
@MainActor
enum AccessibilityMenuBarHelper {

    /// Whether Accessibility permission has been granted (non-blocking check).
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission via the system dialog.
    /// Note: On modern macOS, this dialog only appears once. If previously dismissed
    /// or denied, use `openAccessibilitySettings()` instead.
    static func promptForAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings directly to the Accessibility pane.
    /// This is the reliable fallback when the system prompt doesn't appear.
    static func openAccessibilitySettings() {
        // macOS 13+ (Ventura) URL scheme for Privacy & Security > Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Resolve info (name + icon) for a menu bar item at the given frame.
    static func itemInfo(at frame: CGRect) -> HiddenItemInfo? {
        guard isGranted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?

        let midX = Float(frame.midX)
        let midY = Float(frame.midY)

        let result = AXUIElementCopyElementAtPosition(systemWide, midX, midY, &element)
        guard result == .success, let element else { return nil }

        // Only process actual menu bar items, not random page elements
        let role = axStringAttribute(element, kAXRoleAttribute)
        let subrole = axStringAttribute(element, kAXSubroleAttribute)
        guard role == "AXMenuBarItem" && subrole == "AXMenuExtra" else { return nil }

        return resolveElement(element, frame: frame)
    }

    /// Resolve info for multiple menu bar items. Returns sorted, deduplicated results.
    static func resolveItems(for items: [MenuBarItem]) -> [HiddenItemInfo] {
        guard isGranted else { return [] }

        // Deduplicate by name, keeping first icon and frame per name
        var seen: [String: (icon: NSImage?, frame: CGRect)] = [:]
        var counts: [String: Int] = [:]

        for item in items {
            if let info = itemInfo(at: item.frame) {
                counts[info.name, default: 0] += 1
                if seen[info.name] == nil {
                    seen[info.name] = (icon: info.icon, frame: info.frame)
                }
            }
        }

        return counts.sorted(by: { $0.key < $1.key }).map { name, count in
            let displayName = count > 1 ? "\(name) (\(count))" : name
            let data = seen[name]!
            return HiddenItemInfo(name: displayName, icon: data.icon, frame: data.frame)
        }
    }

    // MARK: - AX Hierarchy Enumeration

    /// Enumerate ALL menu bar extras via the AX tree, regardless of screen position.
    /// This finds items hidden behind the notch that position-based queries miss.
    /// Items are filtered to only include those left of `separatorX` on the given screen.
    static func enumerateAllExtras(leftOf separatorX: CGFloat, screenY: CGFloat) -> [HiddenItemInfo] {
        guard isGranted else { return [] }

        // The "AXExtrasMenuBar" attribute returns the system extras menu bar.
        // Try multiple app PIDs — availability varies by macOS version and
        // which process is frontmost.
        guard let children = extrasMenuBarChildren() else { return [] }

        var seen: [String: (icon: NSImage?, frame: CGRect)] = [:]
        var counts: [String: Int] = [:]

        for child in children {
            let role = axStringAttribute(child, kAXRoleAttribute)
            let subrole = axStringAttribute(child, kAXSubroleAttribute)
            guard role == "AXMenuBarItem" && subrole == "AXMenuExtra" else { continue }

            // Read frame from AX position + size attributes
            let frame = axFrame(of: child)

            // Skip items that aren't in the menu bar area (wrong screen)
            guard abs(frame.midY - screenY) < 30 else { continue }

            // Skip items to the right of the separator — those aren't ours
            guard frame.midX < separatorX else { continue }

            // Resolve name + icon
            guard let info = resolveElement(child, frame: frame) else { continue }

            counts[info.name, default: 0] += 1
            if seen[info.name] == nil {
                seen[info.name] = (icon: info.icon, frame: info.frame)
            }
        }

        return counts.sorted(by: { $0.key < $1.key }).map { name, count in
            let displayName = count > 1 ? "\(name) (\(count))" : name
            let data = seen[name]!
            return HiddenItemInfo(name: displayName, icon: data.icon, frame: data.frame)
        }
    }

    // MARK: - Menu Interaction

    /// Perform AXPress on the menu bar item at the given frame position.
    /// The item must be visible on screen (not pushed off) for this to work.
    @discardableResult
    static func pressItem(at frame: CGRect) -> Bool {
        guard isGranted else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?

        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(frame.midX), Float(frame.midY), &element
        )
        guard result == .success, let element else { return false }

        let role = axStringAttribute(element, kAXRoleAttribute)
        let subrole = axStringAttribute(element, kAXSubroleAttribute)
        guard role == "AXMenuBarItem" && subrole == "AXMenuExtra" else { return false }

        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Press a menu bar extra by matching its resolved name via AX tree traversal.
    /// Unlike `pressItem(at:)`, this works for items behind the notch because
    /// it doesn't depend on screen position for element discovery.
    /// - Parameters:
    ///   - name: The display name (as shown in the context menu). May include " (N)" suffix.
    ///   - screenY: The Y coordinate of the menu bar (for filtering to the correct screen).
    /// - Returns: The AX frame of the pressed element (for menu dismissal polling), or nil on failure.
    static func pressItemByName(_ name: String, screenY: CGFloat) -> CGRect? {
        guard isGranted else {
            snugLog("pressItemByName: AX not granted!")
            return nil
        }
        guard let children = extrasMenuBarChildren() else {
            snugLog("pressItemByName: extrasMenuBarChildren returned nil")
            return nil
        }

        let targetBase = stripCountSuffix(name)
        snugLog("pressItemByName: looking for '%@' (base='%@') among %d children, screenY=%.0f",
              name, targetBase, children.count, screenY)

        var childIndex = 0
        for child in children {
            let role = axStringAttribute(child, kAXRoleAttribute)
            let subrole = axStringAttribute(child, kAXSubroleAttribute)
            if role != "AXMenuBarItem" || subrole != "AXMenuExtra" {
                childIndex += 1
                continue
            }

            let frame = axFrame(of: child)

            // Filter to correct screen by Y coordinate
            let yDiff = abs(frame.midY - screenY)
            if yDiff >= 30 {
                snugLog("  child[%d]: frame=(%.0f,%.0f,%.0f,%.0f) SKIPPED yDiff=%.0f",
                      childIndex, frame.origin.x, frame.origin.y, frame.width, frame.height, yDiff)
                childIndex += 1
                continue
            }

            // Resolve name using the same logic as resolveElement
            guard let info = resolveElement(child, frame: frame) else {
                snugLog("  child[%d]: frame=(%.0f,%.0f) resolveElement returned nil",
                      childIndex, frame.origin.x, frame.origin.y)
                childIndex += 1
                continue
            }
            let childBase = stripCountSuffix(info.name)

            snugLog("  child[%d]: name='%@' (base='%@') frame=(%.0f,%.0f,%.0f,%.0f) match=%d",
                  childIndex, info.name, childBase, frame.origin.x, frame.origin.y,
                  frame.width, frame.height, childBase == targetBase ? 1 : 0)

            if childBase == targetBase {
                // Try AXPress first (preferred — works directly on the element)
                let result = AXUIElementPerformAction(child, kAXPressAction as CFString)
                if result == .success {
                    snugLog("pressItemByName: AXPress SUCCEEDED for '%@' at (%.0f,%.0f,%.0f,%.0f)",
                          name, frame.origin.x, frame.origin.y, frame.width, frame.height)
                    return frame
                }

                snugLog("pressItemByName: AXPress FAILED (error=%d) for '%@' at (%.0f,%.0f), trying CGEvent click",
                      result.rawValue, name, frame.origin.x, frame.origin.y)

                // Fallback: simulate a mouse click at the element's position.
                let clickPoint = CGPoint(x: frame.midX, y: frame.midY)
                snugLog("pressItemByName: CGEvent click target=(%.1f,%.1f)", clickPoint.x, clickPoint.y)

                if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                           mouseCursorPosition: clickPoint, mouseButton: .left),
                   let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                         mouseCursorPosition: clickPoint, mouseButton: .left) {
                    mouseDown.post(tap: .cghidEventTap)
                    usleep(50_000) // 50ms between down/up
                    mouseUp.post(tap: .cghidEventTap)
                    snugLog("pressItemByName: CGEvent click SENT for '%@' at (%.1f,%.1f)", name, clickPoint.x, clickPoint.y)
                    return frame
                }

                snugLog("pressItemByName: CGEvent creation FAILED for '%@'", name)
            }
            childIndex += 1
        }

        snugLog("pressItemByName: could NOT find '%@' among %d children", name, children.count)
        return nil
    }

    /// Strip " (N)" count suffix from a display name for comparison.
    private static func stripCountSuffix(_ name: String) -> String {
        if let range = name.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    /// Check whether the menu bar item at the given position currently has its menu open.
    /// Returns true if the AX element has children (the open menu).
    static func isMenuOpen(at frame: CGRect) -> Bool {
        guard isGranted else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?

        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(frame.midX), Float(frame.midY), &element
        )
        guard result == .success, let element else { return false }

        var children: AnyObject?
        let childResult = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &children
        )
        guard childResult == .success, let childArray = children as? [AXUIElement] else {
            return false
        }

        return !childArray.isEmpty
    }

    /// Check whether a menu bar item's menu is open using AX tree traversal (name-based).
    /// Unlike `isMenuOpen(at:)`, this works for items behind the notch because it
    /// doesn't depend on screen position for element discovery.
    static func isMenuOpenByName(_ name: String, screenY: CGFloat) -> Bool {
        guard isGranted else { return false }
        guard let children = extrasMenuBarChildren() else {
            snugLog("isMenuOpenByName: extrasMenuBarChildren returned nil for '%@'", name)
            return false
        }

        let targetBase = stripCountSuffix(name)

        for child in children {
            let role = axStringAttribute(child, kAXRoleAttribute)
            let subrole = axStringAttribute(child, kAXSubroleAttribute)
            guard role == "AXMenuBarItem" && subrole == "AXMenuExtra" else { continue }

            let frame = axFrame(of: child)
            guard abs(frame.midY - screenY) < 30 else { continue }

            guard let info = resolveElement(child, frame: frame) else { continue }
            let childBase = stripCountSuffix(info.name)

            if childBase == targetBase {
                // Check if this element has children (the open menu)
                var childrenValue: AnyObject?
                let childResult = AXUIElementCopyAttributeValue(
                    child, kAXChildrenAttribute as CFString, &childrenValue
                )
                if childResult == .success,
                   let childArray = childrenValue as? [AXUIElement],
                   !childArray.isEmpty {
                    snugLog("isMenuOpenByName: '%@' HAS children (%d) -> menu IS open", name, childArray.count)
                    return true
                }
                snugLog("isMenuOpenByName: '%@' has NO children (result=%d) -> menu NOT open", name, childResult.rawValue)
                return false
            }
        }

        snugLog("isMenuOpenByName: could not find '%@' among children -> returning false", name)
        return false
    }

    // MARK: - Private

    /// Try to obtain the AXExtrasMenuBar children from multiple candidate processes.
    /// Returns nil if no process exposes the extras menu bar.
    private static func extrasMenuBarChildren() -> [AXUIElement]? {
        // Build list of PIDs to try (deduplicated, order matters)
        var tried = Set<pid_t>()
        var pids: [pid_t] = []
        let ownPID = ProcessInfo.processInfo.processIdentifier

        func add(_ pid: pid_t) {
            if tried.insert(pid).inserted { pids.append(pid) }
        }

        // Frontmost app (often has the attribute)
        if let front = NSWorkspace.shared.frontmostApplication {
            add(front.processIdentifier)
        }

        // Finder (always running)
        if let finder = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) {
            add(finder.processIdentifier)
        }

        // Control Center (hosts third-party extras on modern macOS)
        if let cc = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.controlcenter"
        }) {
            add(cc.processIdentifier)
        }

        // SystemUIServer (hosts extras on older macOS)
        if let suis = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systemuiserver"
        }) {
            add(suis.processIdentifier)
        }

        snugLog("extrasMenuBarChildren: trying %d PIDs: %@ (ownPID=%d excluded from early return)",
              pids.count, pids.map { String($0) }.joined(separator: ", "), ownPID)

        // Try all PIDs and return the LARGEST set of children.
        // Our own app (Snug) may return its own 2 status items via AXExtrasMenuBar,
        // which would incorrectly shadow the real extras from Control Centre.
        // By picking the largest set, we get the actual third-party items.
        var bestChildren: [AXUIElement]?
        var bestCount = 0
        var bestPID: pid_t = 0

        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            var extrasBarValue: AnyObject?
            let barResult = AXUIElementCopyAttributeValue(
                app, "AXExtrasMenuBar" as CFString, &extrasBarValue
            )
            if barResult != .success {
                snugLog("  pid %d: AXExtrasMenuBar failed (error=%d)", pid, barResult.rawValue)
                continue
            }
            guard let extrasBar = extrasBarValue else {
                snugLog("  pid %d: AXExtrasMenuBar nil value", pid)
                continue
            }

            var childrenValue: AnyObject?
            let childResult = AXUIElementCopyAttributeValue(
                extrasBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue
            )
            if let children = childrenValue as? [AXUIElement], !children.isEmpty {
                snugLog("  pid %d: found %d children%@", pid, children.count,
                      pid == ownPID ? " (own app)" : "")
                if children.count > bestCount {
                    bestChildren = children
                    bestCount = children.count
                    bestPID = pid
                }
            } else {
                snugLog("  pid %d: AXExtrasMenuBar found but children empty/nil (result=%d)", pid, childResult.rawValue)
            }
        }

        if let bestChildren {
            snugLog("extrasMenuBarChildren: returning %d children from pid %d", bestCount, bestPID)
            return bestChildren
        }

        snugLog("extrasMenuBarChildren: all PIDs exhausted, returning nil")
        return nil
    }

    /// Resolve name + icon from an AXUIElement that is known to be a menu bar extra.
    private static func resolveElement(_ element: AXUIElement, frame: CGRect) -> HiddenItemInfo? {
        var pid: pid_t = 0
        let app: NSRunningApplication?
        if AXUIElementGetPid(element, &pid) == .success {
            app = NSRunningApplication(processIdentifier: pid)
        } else {
            app = nil
        }

        let axDesc = axStringAttribute(element, kAXDescriptionAttribute)
        let axHelp = axStringAttribute(element, kAXHelpAttribute)
        let axTitle = axStringAttribute(element, kAXTitleAttribute)
        let axIdent = axStringAttribute(element, "AXIdentifier")
        let appName = app?.localizedName

        snugLog("resolveElement: pid=%d app=%@ desc=%@ help=%@ title=%@ ident=%@ frame=(%.0f,%.0f)",
              pid, appName ?? "nil", axDesc ?? "nil", axHelp ?? "nil",
              axTitle ?? "nil", axIdent ?? "nil", frame.origin.x, frame.origin.y)

        let name: String? = {
            if let appName,
               appName != "Control Centre" && appName != "Control Center" {
                return appName
            }
            if let axDesc {
                return axDesc
            }
            if let axHelp {
                return axHelp.components(separatedBy: "\n").first ?? axHelp
            }
            if let axTitle {
                let looksLikeData = axTitle.contains("°") ||
                    axTitle.contains("rpm") ||
                    axTitle.contains("\n") ||
                    axTitle.allSatisfy({ $0.isNumber || $0.isWhitespace || $0 == "%" })
                if !looksLikeData { return axTitle }
            }
            // Last resort: use AXIdentifier if available (e.g., "com.app.statusitem")
            if let axIdent, !axIdent.isEmpty {
                // Clean up identifier — use last component if it looks like a bundle ID
                let components = axIdent.split(separator: ".")
                if components.count > 1, let last = components.last {
                    return String(last).capitalized
                }
                return axIdent
            }
            return nil
        }()

        guard let name, !name.isEmpty else {
            snugLog("resolveElement: FAILED to resolve name for pid=%d at (%.0f,%.0f)",
                  pid, frame.origin.x, frame.origin.y)
            return nil
        }

        let icon: NSImage? = {
            guard let appIcon = app?.icon else { return nil }
            let size = NSSize(width: 16, height: 16)
            let scaled = NSImage(size: size)
            scaled.lockFocus()
            appIcon.draw(in: NSRect(origin: .zero, size: size))
            scaled.unlockFocus()
            return scaled
        }()

        return HiddenItemInfo(name: name, icon: icon, frame: frame)
    }

    /// Read the screen frame of an AX element via its position + size attributes.
    private static func axFrame(of element: AXUIElement) -> CGRect {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        var pos = CGPoint.zero
        var size = CGSize.zero
        if let pv = posValue {
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        }
        if let sv = sizeValue {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        let str = value as? String
        return (str?.isEmpty == false) ? str : nil
    }
}
