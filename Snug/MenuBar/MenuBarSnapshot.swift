import AppKit

/// Immutable snapshot of the hidden menu-bar items at a single point in time.
///
/// Produced by discovery, consumed by the toggle icon, right-click menu, and
/// activate flow. Atomic replacement of the owner's stored `currentSnapshot`
/// is the only legal mutation path — readers see consistent state by
/// construction.
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
/// has been confirmed stable (e.g. seen twice in a row), never from a
/// single transient observation.
///
/// This is the invariant the 6→9 bug violated: `postCollapseItemCount` (the
/// predecessor to `totalCount`) adopted a single transient `allPushedCount=12`
/// reading, and that stale value became the cap for the next expand
/// refresh. Under this type's contract, a transient observation must not
/// update `totalCount` — it must be compared against the prior reading and
/// only promoted when confirmed.
///
/// ## Session-ephemeral
///
/// Never serialize, never persist. `windowID`s and AX handles are
/// session-lifetime; a restored snapshot would reference dead handles.
///
/// ## What NOT to include
///
/// Do not add `AXUIElement` fields — AXUIElement is not `Sendable`, and
/// including one would block moving discovery off the main thread in Step 6.
/// Keep discovery outputs in pure value types (String, CGRect, pid_t, etc.)
/// and re-fetch AX elements by PID at the point of use.
struct MenuBarSnapshot: Sendable {

    /// Stable identity for a status-item owner across snapshots.
    ///
    /// Within a session, `ownerPID` is sufficient: a quit app's PID is not
    /// recycled before our quit-app prune removes its cache entry.
    /// `bundleID` is optional so callers may enrich the key when they have
    /// it (e.g. from `MenuBarItem.bundleID`); the ledger dedupes on `ownerPID`
    /// alone, so adding/missing `bundleID` does not fragment lookups.
    struct StableKey: Hashable, Sendable {
        let ownerPID: pid_t

        init(ownerPID: pid_t) {
            self.ownerPID = ownerPID
        }
    }

    /// Telemetry on how this snapshot was produced. Logging and debugging
    /// only — do NOT branch discovery or merge logic on this value.
    enum Width: Sendable {
        case natural
        case collapsed
        case unknown
    }

    /// Named, resolved items sorted by name. Authoritative for the right-
    /// click menu and the badge count display.
    let items: [HiddenItemInfo]

    /// Known-stable physical count of hidden items. See type-level doc for
    /// the "stability" contract — this field must NOT carry transient
    /// observations.
    let totalCount: Int

    /// Last-known natural-width X per item, keyed by stable identity. Used
    /// by the activate flow to decide how far to Cmd+drag an item back.
    let naturalPositions: [StableKey: CGFloat]

    /// Sticky name ledger carried across snapshots so behind-notch items
    /// retain their names when a fresh natural-width scan can't re-resolve
    /// them. Writers seed this from the prior snapshot.
    let resolvedNames: [StableKey: String]

    let capturedAt: Date
    let capturedWidth: Width

    static let empty = MenuBarSnapshot(
        items: [],
        totalCount: 0,
        naturalPositions: [:],
        resolvedNames: [:],
        capturedAt: .distantPast,
        capturedWidth: .unknown
    )
}
