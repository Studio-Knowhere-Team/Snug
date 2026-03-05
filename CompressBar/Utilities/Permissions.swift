import AppKit

/// Snug uses CGWindowListCopyWindowInfo at layer 25 for position/size/PID
/// without Screen Recording. Accessibility permission is optionally requested to
/// resolve real names of hidden menu bar items via AXUIElement.
@MainActor
enum Permissions {
    // Core functionality requires no permissions.
    // Accessibility is optional — see AccessibilityMenuBarHelper.
}
