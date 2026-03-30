import AppKit

/// Represents a single status bar item discovered in the menu bar.
struct MenuBarItem: Identifiable, Sendable {
    let windowID: CGWindowID
    let frame: CGRect
    let ownerPID: pid_t
    let ownerName: String
    let bundleID: String?
    let title: String?

    var id: CGWindowID { windowID }
}
