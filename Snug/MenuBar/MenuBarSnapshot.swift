import AppKit

/// Immutable snapshot of the hidden menu-bar items at a single point in time.
///
/// Produced by discovery, consumed by the toggle icon and right-click menu.
/// Atomic replacement of the owner's stored `currentSnapshot` is the only
/// legal mutation path — readers see consistent state by construction.
///
/// ## Why a value type
///
/// The bug history that motivated this type is a sequence of torn-read
/// incidents: `cachedHiddenItemInfo`, `cachedHiddenItems`, and
/// `postCollapseItemCount` were updated across ~25-line merge blocks, and
/// any reader that touched them mid-block (right-click menu builder, badge
/// icon updater) saw inconsistent combinations. A value type assigned once
/// cannot be torn; the whole thing either is or isn't the new state.
///
/// ## What `totalCount` means
///
/// `totalCount` is the **known-stable** physical count of hidden items. It
/// is *not* simply `items.count` — a snapshot can know the count (via
/// CGWindowList post-collapse) without having resolved every name yet, in
/// which case `items.count < totalCount`. Writers must treat it as
/// trust-earned: adopt a new `totalCount` only when the underlying reading
/// has been confirmed stable (via `CacheMerge.promoteCountIfStable`), never
/// from a single transient observation.
///
/// This is the invariant the 6→9 bug violated: `postCollapseItemCount` (the
/// input to `totalCount`) adopted a single transient `allPushedCount=12`
/// reading, and that stale value became the cap for the next expand
/// refresh. Under this type's contract, a transient observation must not
/// update `totalCount` — it must be compared against the prior reading and
/// only promoted when confirmed.
///
/// ## Session-ephemeral
///
/// Never serialize, never persist. `windowID`s are session-lifetime; a
/// restored snapshot would reference dead windows.
///
/// ## What NOT to include
///
/// Do not add `AXUIElement` fields — AXUIElement is not `Sendable`, and
/// including one would force discovery back onto the main thread. Keep
/// discovery outputs in pure value types (String, CGRect, pid_t, etc.)
/// and re-fetch AX elements by PID at the point of use.
struct MenuBarSnapshot: Sendable {

    /// Telemetry on how this snapshot was produced. Logging and debugging
    /// only — do NOT branch discovery or merge logic on this value.
    enum Width: Sendable {
        case natural
        case collapsed
        case unknown
    }

    /// Named, resolved items sorted by name. Authoritative for the right-
    /// click menu.
    let items: [HiddenItemInfo]

    /// Known-stable physical count of hidden items. Authoritative for the
    /// badge. See type-level doc for the "stability" contract — this field
    /// must NOT carry transient observations. Always >= `items.count`.
    let totalCount: Int

    let capturedAt: Date
    let capturedWidth: Width

    static let empty = MenuBarSnapshot(
        items: [],
        totalCount: 0,
        capturedAt: .distantPast,
        capturedWidth: .unknown
    )
}
