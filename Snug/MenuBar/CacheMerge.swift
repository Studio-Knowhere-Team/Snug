import AppKit

/// Pure reconciliation logic for the hidden-item cache.
///
/// Extracted from `StatusBarController` so the merge/trim rules can be unit-
/// tested with scripted fixtures. These functions **must not** touch NSStatusItem,
/// NSScreen, AX, or CGWindowList — they are pure transforms over value types.
///
/// The three public entry points mirror the three places hidden-item state is
/// reconciled in the live controller:
///
/// - `promoteCountIfStable` — the stability gate deciding when a new
///   post-collapse count observation becomes authoritative.
///
/// - `applyPostCollapseDiscovery` — after a collapse, when CGWindowList sees
///   items that were previously behind the notch. The authoritative count is
///   the **stable** count (post-gate), never a raw transient observation.
///
/// - `applyRefreshAfterExpand` — on expand, when natural-width AX can resolve
///   names for visible items. Behind-notch items aren't visible at this width,
///   so the cache preserves prior entries up to the last-known authoritative
///   count (`postCollapseItemCount`).
enum CacheMerge {

    /// Strip a trailing `" (N)"` count suffix so `"Dropbox (2)"` matches
    /// `"Dropbox"` during dedup.
    static func baseName(of displayName: String) -> String {
        if let range = displayName.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            return String(displayName[..<range.lowerBound])
        }
        return displayName
    }

    /// Whether a window-owner name is Control Centre, which hosts third-party
    /// status items on modern macOS — grouping by its name is meaningless.
    /// Both spellings appear depending on system locale.
    static func isControlCentre(_ name: String) -> Bool {
        name == "Control Centre" || name == "Control Center"
    }

    /// Group per-window entries by name, keeping the first entry per name and
    /// rendering duplicates as `"Name (N)"`. Result is sorted by name.
    ///
    /// Pass one `HiddenItemInfo` per physical item (name WITHOUT a count
    /// suffix); this is the single implementation behind the AX position
    /// scan, the process-metadata scan, and the per-app AX scan.
    static func dedupeByName(_ entries: [HiddenItemInfo]) -> [HiddenItemInfo] {
        var seen: [String: HiddenItemInfo] = [:]
        var counts: [String: Int] = [:]

        for entry in entries {
            counts[entry.name, default: 0] += 1
            if seen[entry.name] == nil {
                seen[entry.name] = entry
            }
        }

        return counts.sorted(by: { $0.key < $1.key }).compactMap { name, count in
            guard let first = seen[name] else { return nil }
            let displayName = count > 1 ? "\(name) (\(count))" : name
            return HiddenItemInfo(
                name: displayName,
                icon: first.icon,
                frame: first.frame,
                windowID: first.windowID,
                ownerPID: first.ownerPID
            )
        }
    }

    /// Decide whether a newly-observed post-collapse item count should
    /// replace the current authoritative count, or be held as a pending
    /// reading until it's confirmed by a second matching observation.
    ///
    /// This is the core of the 6→9 bug fix. Previously, any single
    /// `allPushedCount` observation became `postCollapseItemCount`, and a
    /// single transient inflation (e.g. `12` during a display reconfig
    /// where CGWindowList briefly duplicates items) became the stale cap
    /// in `applyRefreshAfterExpand` — preserving phantoms across the next
    /// expand.
    ///
    /// With the stability gate:
    ///   - `observed == current`: steady state; clear pending.
    ///   - `observed == pending`: confirmed; promote.
    ///   - otherwise: record `observed` as pending, don't update current.
    ///
    /// Callers must call this on every post-collapse discovery and carry
    /// the returned `newPending` forward into the next call.
    static func promoteCountIfStable(
        observed: Int,
        current: Int,
        pending: Int?
    ) -> (newCount: Int, newPending: Int?) {
        if observed == current {
            return (current, nil)
        }
        if let pending, pending == observed {
            return (observed, nil)
        }
        return (current, observed)
    }

    /// Reconcile the cache after a post-collapse discovery pass.
    ///
    /// - Parameters:
    ///   - cache: current `cachedHiddenItemInfo`.
    ///   - stableCount: the authoritative count — the output of
    ///     `promoteCountIfStable`, NOT a raw `allPushedCount` observation.
    ///     Using the stable count here is what stops a transient inflation
    ///     from admitting phantoms: during a transient, the stable count
    ///     hasn't moved, so the gap is 0 and per-app results are ignored.
    ///   - newItemsByProcess: items resolved from the process-based pass
    ///     (`resolveItemsByProcess`), already deduped. Merged unconditionally
    ///     because they're CGWindowList-backed (high confidence).
    ///   - perAppResolved: items resolved from the per-app AX scan
    ///     (`enumerateExtrasByRunningApps`), already deduped. Pass an empty
    ///     array if the scan wasn't run (gap was zero). Only fills the gap
    ///     between `stableCount` and the cache — lower confidence.
    ///   - isAppRunning: predicate returning true when a `pid_t` belongs to a
    ///     still-running app. Used to prune quit-app entries. Pure function
    ///     so tests can inject a fake running-app set.
    /// - Returns: the new cache contents.
    static func applyPostCollapseDiscovery(
        cache: [HiddenItemInfo],
        stableCount: Int,
        newItemsByProcess: [HiddenItemInfo],
        perAppResolved: [HiddenItemInfo],
        isAppRunning: (pid_t) -> Bool
    ) -> [HiddenItemInfo] {
        // 1. Prune quit-app entries.
        var next = cache.filter { isAppRunning($0.ownerPID) }

        // 2. Add new process-resolved items that aren't already in cache.
        let afterPruneNames = Set(next.map { baseName(of: $0.name) })
        let uniqueFromProcess = newItemsByProcess.filter {
            !afterPruneNames.contains(baseName(of: $0.name))
        }
        if !uniqueFromProcess.isEmpty {
            next.append(contentsOf: uniqueFromProcess)
            next.sort { $0.name < $1.name }
        }

        // 3. Gap-gated per-app merge. Only fill the gap between the stable
        //    count and what we already have. Prevents transient per-app
        //    phantoms from inflating the cache.
        let gap = max(0, stableCount - next.count)
        if gap > 0 && !perAppResolved.isEmpty {
            let existingNamesNow = Set(next.map { baseName(of: $0.name) })
            let newFromApps = perAppResolved.filter {
                !existingNamesNow.contains(baseName(of: $0.name))
            }
            let limited = Array(newFromApps.prefix(gap))
            if !limited.isEmpty {
                next.append(contentsOf: limited)
                next.sort { $0.name < $1.name }
            }
        }

        // 4. Trim cache if it's overshot the stable count. Prefer dropping
        //    `windowID == 0` entries first (per-app-scan origin; lower
        //    confidence than CGWindowList-sourced entries with real IDs).
        if stableCount > 0 && next.count > stableCount {
            let ranked = next.sorted { a, b in
                if (a.windowID != 0) != (b.windowID != 0) {
                    return a.windowID != 0
                }
                return a.name < b.name
            }
            next = Array(ranked.prefix(stableCount))
                .sorted { $0.name < $1.name }
        }

        return next
    }

    /// Reconcile the cache on expand.
    ///
    /// - Parameters:
    ///   - cache: current `cachedHiddenItemInfo`.
    ///   - freshInfo: items resolved via AX at natural width in this refresh.
    ///   - hiddenCount: `itemsLeftOfSeparator().count` at expanded width.
    ///     On notched displays this undercounts (behind-notch items have no
    ///     window at natural width), which is why we also consult
    ///     `postCollapseItemCount`.
    ///   - postCollapseItemCount: last-known authoritative count. Protected
    ///     by the stability gate, so a transient display event cannot
    ///     inflate it (see `promoteCountIfStable`).
    ///   - isAppRunning: predicate returning true when a `pid_t` belongs to a
    ///     still-running app. Prunes quit-app entries that would otherwise
    ///     survive an entire expanded session — post-collapse discovery also
    ///     prunes, but it can be skipped when the user expands mid-scan.
    /// - Returns: the new cache contents.
    static func applyRefreshAfterExpand(
        cache: [HiddenItemInfo],
        freshInfo: [HiddenItemInfo],
        hiddenCount: Int,
        postCollapseItemCount: Int,
        isAppRunning: (pid_t) -> Bool
    ) -> [HiddenItemInfo] {
        // Preserve prior entries whose names aren't in freshInfo and whose
        // owning app is still running. The name misses are typically
        // behind-notch items that need to carry over.
        let freshNames = Set(freshInfo.map { baseName(of: $0.name) })
        let preserved = cache.filter {
            !freshNames.contains(baseName(of: $0.name)) && isAppRunning($0.ownerPID)
        }

        // Cap at the target count. Prefer hiddenCount on the notched MBP case
        // where postCollapseItemCount covers behind-notch items invisible here.
        let target = max(hiddenCount, postCollapseItemCount)
        let slotsForPreserved = max(0, target - freshInfo.count)

        // Rank preserved entries so CGWindowList-sourced (windowID != 0) beat
        // per-app-sourced (windowID == 0) when slots are limited.
        let rankedPreserved = preserved.sorted { a, b in
            if (a.windowID != 0) != (b.windowID != 0) {
                return a.windowID != 0
            }
            return a.name < b.name
        }
        let keptPreserved = Array(rankedPreserved.prefix(slotsForPreserved))

        return (freshInfo + keptPreserved).sorted { $0.name < $1.name }
    }
}
