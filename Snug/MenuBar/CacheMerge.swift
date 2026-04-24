import AppKit

/// Pure reconciliation logic for the hidden-item cache.
///
/// Extracted from `StatusBarController` so the merge/trim rules can be unit-
/// tested with scripted fixtures. These functions **must not** touch NSStatusItem,
/// NSScreen, AX, or CGWindowList — they are pure transforms over value types.
///
/// The two public entry points mirror the two places `cachedHiddenItemInfo` is
/// reconciled in the live controller:
///
/// - `applyPostCollapseDiscovery` — after a collapse, when CGWindowList sees
///   items that were previously behind the notch. Authoritative count is
///   `allPushed.count` (from CGWindowList layer 25 post-collapse).
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

    /// Reconcile the cache after a post-collapse discovery pass.
    ///
    /// - Parameters:
    ///   - cache: current `cachedHiddenItemInfo`.
    ///   - allPushedCount: `allItemsPushedBySeparator().count` — authoritative.
    ///   - newItemsByProcess: items resolved from the process-based pass
    ///     (`resolveItemsByProcess`), already deduped.
    ///   - perAppResolved: items resolved from the per-app AX scan
    ///     (`enumerateExtrasByRunningApps`), already deduped. Pass an empty
    ///     array if the scan wasn't run (gap was zero).
    ///   - isAppRunning: predicate returning true when a `pid_t` belongs to a
    ///     still-running app. Used to prune quit-app entries. Pure function
    ///     so tests can inject a fake running-app set.
    /// - Returns: the new cache contents **and** the new `postCollapseItemCount`.
    ///   Callers overwrite both atomically.
    static func applyPostCollapseDiscovery(
        cache: [HiddenItemInfo],
        allPushedCount: Int,
        newItemsByProcess: [HiddenItemInfo],
        perAppResolved: [HiddenItemInfo],
        isAppRunning: (pid_t) -> Bool
    ) -> (cache: [HiddenItemInfo], postCollapseItemCount: Int) {
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

        // 3. Gap-gated per-app merge. Only fill the gap between authoritative
        //    count and what we already have. Prevents transient per-app
        //    phantoms from inflating the cache.
        let gap = max(0, allPushedCount - next.count)
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

        // 4. Trim cache if it's overshot the authoritative count. Prefer
        //    dropping `windowID == 0` entries first (per-app-scan origin;
        //    lower confidence than CGWindowList-sourced entries with real IDs).
        if allPushedCount > 0 && next.count > allPushedCount {
            let ranked = next.sorted { a, b in
                if (a.windowID != 0) != (b.windowID != 0) {
                    return a.windowID != 0
                }
                return a.name < b.name
            }
            next = Array(ranked.prefix(allPushedCount))
                .sorted { $0.name < $1.name }
        }

        return (cache: next, postCollapseItemCount: allPushedCount)
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
    ///   - postCollapseItemCount: last-known authoritative count. May be stale
    ///     (pre-existing bug: can be inflated by a transient display event).
    /// - Returns: the new cache contents.
    static func applyRefreshAfterExpand(
        cache: [HiddenItemInfo],
        freshInfo: [HiddenItemInfo],
        hiddenCount: Int,
        postCollapseItemCount: Int
    ) -> [HiddenItemInfo] {
        // Preserve prior entries whose names aren't in freshInfo. These are
        // typically behind-notch items that need to carry over — but can also
        // be phantoms left from a previous transient.
        let freshNames = Set(freshInfo.map { baseName(of: $0.name) })
        let preserved = cache.filter {
            !freshNames.contains(baseName(of: $0.name))
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
