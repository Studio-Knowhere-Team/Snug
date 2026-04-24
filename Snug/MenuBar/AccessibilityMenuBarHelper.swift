import AppKit
import ApplicationServices

/// Resolved info for a hidden menu bar item.
struct HiddenItemInfo: Sendable {
    let name: String
    let icon: NSImage?
    /// Natural screen position (Quartz coords) for re-querying via AX.
    let frame: CGRect
    /// CGWindowList window ID (0 if unknown, e.g. from AX tree enumeration).
    let windowID: CGWindowID
    /// PID of the process that owns this status item (0 if unknown).
    let ownerPID: pid_t
}

/// Provides optional Accessibility API (AXUIElement) integration for resolving
/// the real names of menu bar status items. On modern macOS, third-party items
/// are hosted by Control Centre, so CGWindowList can't identify them.
/// This helper uses AXUIElementCopyElementAtPosition to query items by their
/// known screen positions and read their accessibility descriptions.
@MainActor
enum AccessibilityMenuBarHelper {

    /// System widget names to filter out — these are macOS system items, not third-party extras.
    static let systemWidgetNames: Set<String> = [
        "Audio and Video Controls",
        "Now Playing",
        "Focus",
    ]

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

    /// Press a menu bar extra to open its status menu.
    /// Walks the AX tree to find the element by owner PID — works even if the
    /// item is off-screen or behind the notch (no coordinates needed).
    /// Falls back to position-based lookup if the tree walk fails.
    @discardableResult
    static func pressItem(named name: String, ownerPID: pid_t, fallbackFrame: CGRect) -> Bool {
        guard isGranted else { return false }

        // Primary: walk the AX tree to find the element by PID
        if ownerPID != 0, let element = findExtraByPID(ownerPID) {
            snugLog("pressItem: found '%@' in AX tree (pid=%d), pressing", name, ownerPID)
            let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
            snugLog("pressItem: AXPress result=%d (0=success)", pressResult.rawValue)
            if pressResult == .success { return true }
        }

        // Fallback: position-based lookup
        snugLog("pressItem: tree walk failed for '%@', trying position (%.0f, %.0f)",
              name, fallbackFrame.midX, fallbackFrame.midY)
        return pressItemAtPosition(fallbackFrame)
    }

    /// Press a menu bar item at screen coordinates. Only works if the item is visible.
    private static func pressItemAtPosition(_ frame: CGRect) -> Bool {
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

    /// Find a menu bar extra in the AX tree by its owner PID.
    /// Queries the TARGET APP's own AXExtrasMenuBar directly — this works because
    /// each app exposes its own status item(s) via its AXExtrasMenuBar attribute,
    /// whereas Control Centre's AXExtrasMenuBar reports all children as its own PID.
    private static func findExtraByPID(_ targetPID: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(targetPID)

        var extrasBarValue: AnyObject?
        let barResult = AXUIElementCopyAttributeValue(
            app, "AXExtrasMenuBar" as CFString, &extrasBarValue
        )
        guard barResult == .success, let extrasBar = extrasBarValue else {
            snugLog("findExtraByPID: pid %d has no AXExtrasMenuBar (error=%d)",
                  targetPID, barResult.rawValue)
            return nil
        }

        // swiftlint:disable:next force_cast — CF type bridging always succeeds
        let bar = extrasBar as! AXUIElement

        var childrenValue: AnyObject?
        AXUIElementCopyAttributeValue(
            bar, kAXChildrenAttribute as CFString, &childrenValue
        )
        guard let children = childrenValue as? [AXUIElement], !children.isEmpty else {
            snugLog("findExtraByPID: pid %d AXExtrasMenuBar has no children", targetPID)
            return nil
        }

        snugLog("findExtraByPID: pid %d has %d extras bar children", targetPID, children.count)

        for child in children {
            let role = axStringAttribute(child, kAXRoleAttribute)
            let subrole = axStringAttribute(child, kAXSubroleAttribute)
            guard role == "AXMenuBarItem" && subrole == "AXMenuExtra" else { continue }
            // Return the first matching menu extra from this app
            return child
        }

        snugLog("findExtraByPID: pid %d — no AXMenuExtra children found", targetPID)
        return nil
    }

    /// Resolve info (name + icon) for a menu bar item at the given frame.
    static func itemInfo(at frame: CGRect, windowID: CGWindowID = 0) -> HiddenItemInfo? {
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

        return resolveElement(element, frame: frame, windowID: windowID)
    }

    /// Resolve info for multiple menu bar items. Returns sorted, deduplicated results.
    static func resolveItems(for items: [MenuBarItem]) -> [HiddenItemInfo] {
        guard isGranted else { return [] }

        // Deduplicate by name, keeping first icon, frame, windowID, and ownerPID per name
        var seen: [String: (icon: NSImage?, frame: CGRect, windowID: CGWindowID, ownerPID: pid_t)] = [:]
        var counts: [String: Int] = [:]

        for item in items {
            if let info = itemInfo(at: item.frame, windowID: item.windowID) {
                counts[info.name, default: 0] += 1
                if seen[info.name] == nil {
                    seen[info.name] = (icon: info.icon, frame: info.frame, windowID: item.windowID, ownerPID: info.ownerPID)
                }
            }
        }

        return counts.sorted(by: { $0.key < $1.key }).compactMap { name, count in
            guard let data = seen[name] else { return nil }
            let displayName = count > 1 ? "\(name) (\(count))" : name
            return HiddenItemInfo(name: displayName, icon: data.icon, frame: data.frame, windowID: data.windowID, ownerPID: data.ownerPID)
        }
    }

    // MARK: - AX Hierarchy Enumeration

    /// Enumerate status items by walking every running application and asking
    /// each one directly for its own `AXExtrasMenuBar` children.
    ///
    /// This is the only reliable way to name behind-the-notch items on a
    /// notched MacBook. CGWindowList reports such items as owned by
    /// `Control Centre` (which multiplexes third-party items), and querying
    /// Control Centre's `AXExtrasMenuBar` returns elements that don't carry
    /// resolvable names. But when you query the TARGET app's own AX
    /// application, it returns its own status item(s) with the real PID and
    /// therefore the real app name.
    ///
    /// Returns items filtered to those left of `separatorX` so we only report
    /// items that would be hidden by the separator when collapsed.
    static func enumerateExtrasByRunningApps(leftOf separatorX: CGFloat) -> [HiddenItemInfo] {
        guard isGranted else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seen: [String: (icon: NSImage?, frame: CGRect, ownerPID: pid_t)] = [:]
        var counts: [String: Int] = [:]

        // Only accessory/regular apps can own status items; agents can't.
        // Skipping prohibited apps cuts the enumeration cost substantially.
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != ownPID &&
                app.activationPolicy != .prohibited
        }

        for app in candidates {
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)

            var extrasBarValue: AnyObject?
            let barResult = AXUIElementCopyAttributeValue(
                axApp, "AXExtrasMenuBar" as CFString, &extrasBarValue
            )
            guard barResult == .success, let extrasBar = extrasBarValue else {
                continue
            }

            // swiftlint:disable:next force_cast — CF type bridging always succeeds
            let bar = extrasBar as! AXUIElement

            var childrenValue: AnyObject?
            AXUIElementCopyAttributeValue(
                bar, kAXChildrenAttribute as CFString, &childrenValue
            )
            guard let children = childrenValue as? [AXUIElement], !children.isEmpty else {
                continue
            }

            for child in children {
                let role = axStringAttribute(child, kAXRoleAttribute)
                let subrole = axStringAttribute(child, kAXSubroleAttribute)
                guard role == "AXMenuBarItem" && subrole == "AXMenuExtra" else { continue }

                let frame = axFrame(of: child)

                // If we have a non-zero frame and it's right of the separator,
                // it's not hidden by us. A zero frame means the item is
                // behind-the-notch or otherwise unpositioned — still include it
                // because those are the very items we need this path to catch.
                if frame.width > 0 && frame.midX >= separatorX { continue }

                let name = app.localizedName ?? "Unknown"

                // Skip system widgets and Control Centre itself (shouldn't
                // appear here given we're querying the owning app directly,
                // but belt-and-braces).
                guard !systemWidgetNames.contains(name) else { continue }
                guard name != "Control Centre" && name != "Control Center" else { continue }

                counts[name, default: 0] += 1
                if seen[name] == nil {
                    let icon = app.icon?.scaled(to: NSSize(width: 16, height: 16))
                    seen[name] = (icon: icon, frame: frame, ownerPID: pid)
                }
            }
        }

        return counts.sorted(by: { $0.key < $1.key }).compactMap { name, count in
            guard let data = seen[name] else { return nil }
            let displayName = count > 1 ? "\(name) (\(count))" : name
            return HiddenItemInfo(
                name: displayName,
                icon: data.icon,
                frame: data.frame,
                windowID: 0,
                ownerPID: data.ownerPID
            )
        }
    }

    // MARK: - Private

    /// Resolve name + icon from an AXUIElement that is known to be a menu bar extra.
    private static func resolveElement(_ element: AXUIElement, frame: CGRect, windowID: CGWindowID = 0) -> HiddenItemInfo? {
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

        // Skip system control widgets that aren't real third-party status items.
        if systemWidgetNames.contains(name) {
            snugLog("resolveElement: skipping system widget '%@'", name)
            return nil
        }

        let icon: NSImage? = app?.icon?.scaled(to: NSSize(width: 16, height: 16))

        return HiddenItemInfo(name: name, icon: icon, frame: frame, windowID: windowID, ownerPID: pid)
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
            // CF type bridging — AXValue cast always succeeds
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        }
        if let sv = sizeValue {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    // MARK: - Move Item (Cmd+Drag)

    /// Move a menu bar extra from its current position to a target X using
    /// synthetic Cmd+drag events.  Returns true if the drag was dispatched.
    /// The drag happens in Quartz (top-left origin) screen coordinates.
    /// The cursor is hidden during the operation so the user sees nothing.
    nonisolated static func moveItem(from sourceX: CGFloat, to targetX: CGFloat, menuBarY: CGFloat) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let y = menuBarY

        // Save current mouse position so we can restore it afterwards.
        let savedPos = CGEvent(source: nil)?.location ?? CGPoint(x: sourceX, y: y)

        // Hide cursor so the drag is invisible to the user.
        // defer ensures cursor is always restored, even if CGEvent creation fails mid-sequence.
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(savedPos)
            CGDisplayShowCursor(CGMainDisplayID())
        }

        let cmdFlag = CGEventFlags.maskCommand

        // 1. Cmd + mouse-down at the item's center
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: sourceX, y: y),
            mouseButton: .left
        ) else {
            return false
        }
        mouseDown.flags = cmdFlag
        mouseDown.post(tap: .cghidEventTap)

        // 2. Small nudge to engage the drag mode
        usleep(10_000) // 10ms
        let nudge = sourceX + (targetX > sourceX ? 3 : -3)
        if let drag = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: nudge, y: y),
            mouseButton: .left
        ) {
            drag.flags = cmdFlag
            drag.post(tap: .cghidEventTap)
        }
        usleep(10_000)

        // 3. Drag to target in a few steps for reliability
        let steps = 4
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = sourceX + (targetX - sourceX) * t
            if let drag = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: CGPoint(x: x, y: y),
                mouseButton: .left
            ) {
                drag.flags = cmdFlag
                drag.post(tap: .cghidEventTap)
            }
            usleep(8_000) // 8ms per step
        }

        // 4. Mouse-up at the target
        usleep(8_000)
        if let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: targetX, y: y),
            mouseButton: .left
        ) {
            mouseUp.flags = cmdFlag
            mouseUp.post(tap: .cghidEventTap)
        }

        usleep(5_000)
        // Cursor restored by defer block above.

        snugLog("moveItem: dragged from x=%.0f to x=%.0f (y=%.0f)", sourceX, targetX, y)
        return true
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        let str = value as? String
        return (str?.isEmpty == false) ? str : nil
    }
}
