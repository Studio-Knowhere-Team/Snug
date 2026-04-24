import XCTest
import AppKit
@testable import Snug

/// Exercises `CacheMerge` with fixtures that reproduce the 6→9 phantom
/// inflation observed in production logs on 2026-04-24. The goal of these
/// tests is to demonstrate — before any architectural refactor — that the
/// reconciliation logic itself can produce and preserve phantom entries when
/// a transient `allPushedCount` inflates `postCollapseItemCount` and a
/// subsequent expand refresh preserves the extras.
final class CacheMergeTests: XCTestCase {

    // MARK: - Helpers

    private func info(_ name: String, pid: pid_t = 1000, wid: CGWindowID = 0) -> HiddenItemInfo {
        HiddenItemInfo(
            name: name,
            icon: nil,
            frame: .zero,
            windowID: wid,
            ownerPID: pid
        )
    }

    /// Six "real" items with real CGWindowIDs — represents what we'd get
    /// from CGWindowList + AX natural-width resolution on an external
    /// display with no notch.
    private func sixRealItems() -> [HiddenItemInfo] {
        [
            info("Claude",    pid: 41016, wid: 1001),
            info("Codex",     pid: 21331, wid: 1002),
            info("Flux",      pid:  5780, wid: 1003),
            info("Rectangle", pid:  5039, wid: 1004),
            info("TopNotch",  pid:  5138, wid: 1005),
            info("Upwork",    pid:  1353, wid: 1006),
        ]
    }

    /// Three phantom items with windowID == 0 — represents the per-app scan
    /// returning apps whose status items briefly have zero frames during a
    /// display transition.
    private func threePhantoms() -> [HiddenItemInfo] {
        [
            info("Folder Peek",       pid: 7001, wid: 0),
            info("Macs Fan Control",  pid: 7002, wid: 0),
            info("Natter",            pid: 7003, wid: 0),
        ]
    }

    private func allRunning(_ pid: pid_t) -> Bool { true }

    // MARK: - Baseline

    func testBaseName_stripsCountSuffix() {
        XCTAssertEqual(CacheMerge.baseName(of: "Dropbox"), "Dropbox")
        XCTAssertEqual(CacheMerge.baseName(of: "Dropbox (2)"), "Dropbox")
        XCTAssertEqual(CacheMerge.baseName(of: "App (12)"), "App")
        XCTAssertEqual(CacheMerge.baseName(of: "App (1.5)"), "App (1.5)")  // non-integer: not stripped
    }

    func testStableState_postCollapseDoesNothing() {
        let cache = sixRealItems()
        let (next, count) = CacheMerge.applyPostCollapseDiscovery(
            cache: cache,
            allPushedCount: 6,
            newItemsByProcess: [],
            perAppResolved: [],
            isAppRunning: allRunning
        )
        XCTAssertEqual(next.map(\.name), cache.map(\.name))
        XCTAssertEqual(count, 6)
    }

    func testQuitApp_isPruned() {
        let cache = sixRealItems()
        let runningExceptFlux: (pid_t) -> Bool = { $0 != 5780 }
        let (next, _) = CacheMerge.applyPostCollapseDiscovery(
            cache: cache,
            allPushedCount: 5,
            newItemsByProcess: [],
            perAppResolved: [],
            isAppRunning: runningExceptFlux
        )
        XCTAssertFalse(next.contains { $0.name == "Flux" })
        XCTAssertEqual(next.count, 5)
    }

    func testBehindNotchGap_filledByPerApp() {
        // Scenario: on notched MBP, process-based resolution only gets 4 of 6
        // items; the per-app scan returns the full 6 with real names.
        let cache: [HiddenItemInfo] = []
        let fourReal = Array(sixRealItems().prefix(4))
        let allSix = sixRealItems().map { info($0.name, pid: $0.ownerPID, wid: 0) }

        let (next, count) = CacheMerge.applyPostCollapseDiscovery(
            cache: cache,
            allPushedCount: 6,
            newItemsByProcess: fourReal,
            perAppResolved: allSix,
            isAppRunning: allRunning
        )
        XCTAssertEqual(next.count, 6)
        XCTAssertEqual(count, 6)
        XCTAssertEqual(Set(next.map(\.name)), Set(sixRealItems().map(\.name)))
    }

    // MARK: - Phantom inflation repro

    /// Reproduces the first half of the 6→9 bug: a transient where
    /// `allPushedCount` is inflated (simulating a display-transition where
    /// CGWindowList duplicates items across displays) and the per-app scan
    /// surfaces phantoms (apps whose extras are actually visible elsewhere but
    /// have zero AX frames during realization). With the current logic, the
    /// phantoms are admitted into the cache because the gap allows them.
    func testPostCollapseDiscovery_inflatesCacheOnTransientGap() {
        let cache = sixRealItems()

        // Display glitch: allPushedCount=12 (duplicated across displays),
        // per-app scan sees 6 real + 3 phantoms.
        let (next, count) = CacheMerge.applyPostCollapseDiscovery(
            cache: cache,
            allPushedCount: 12,
            newItemsByProcess: [],
            perAppResolved: sixRealItems() + threePhantoms(),
            isAppRunning: allRunning
        )

        // EXPECTED OUTCOME (bug): cache grows to 9 — the 6 real items plus
        // all 3 phantoms fit under the inflated cap of 12.
        XCTAssertEqual(next.count, 9,
            "Baseline repro: transient cap=12 lets phantoms in.")
        XCTAssertEqual(count, 12,
            "postCollapseItemCount adopts the transient value.")
        XCTAssertTrue(next.contains { $0.name == "Folder Peek" })
        XCTAssertTrue(next.contains { $0.name == "Macs Fan Control" })
        XCTAssertTrue(next.contains { $0.name == "Natter" })
    }

    /// Reproduces the full 6→9 bug across a two-call sequence:
    ///  (1) postCollapseDiscovery with transient `allPushedCount=12` inflates
    ///      the cache to 9 items **and** sets `postCollapseItemCount=12`.
    ///  (2) User expands. `refreshAfterExpand` runs with fresh CGWindowList
    ///      reporting only 6 real items (`hiddenCount=6`) but the stale
    ///      `postCollapseItemCount=12` is used as the cap, so 3 phantoms are
    ///      preserved instead of trimmed.
    ///
    /// This matches the production log's sequence exactly.
    func testInflatedPostCollapseCount_preservesPhantomsOnExpand() {
        // Phase 1: transient post-collapse inflates cache + count.
        let (inflatedCache, staleCount) = CacheMerge.applyPostCollapseDiscovery(
            cache: sixRealItems(),
            allPushedCount: 12,
            newItemsByProcess: [],
            perAppResolved: sixRealItems() + threePhantoms(),
            isAppRunning: allRunning
        )
        XCTAssertEqual(inflatedCache.count, 9, "sanity: phase 1 inflated")
        XCTAssertEqual(staleCount, 12, "sanity: stale count set to transient")

        // Phase 2: user expands. Reality is 6. freshInfo resolves the 6 real
        // items. postCollapseItemCount is still the stale 12.
        let refreshed = CacheMerge.applyRefreshAfterExpand(
            cache: inflatedCache,
            freshInfo: sixRealItems(),
            hiddenCount: 6,
            postCollapseItemCount: staleCount  // stale 12
        )

        // EXPECTED OUTCOME (bug): cache stays at 9 because the stale cap=12
        // provides 6 slots for preserved entries, and 3 of the preserved are
        // the phantoms. The user sees 9 items on badge and in the dropdown,
        // with 3 that don't exist.
        XCTAssertEqual(refreshed.count, 9,
            "BUG: stale postCollapseItemCount lets phantoms survive expand-refresh.")
        XCTAssertTrue(refreshed.contains { $0.name == "Folder Peek" },
            "phantom survived")
        XCTAssertTrue(refreshed.contains { $0.name == "Macs Fan Control" },
            "phantom survived")
        XCTAssertTrue(refreshed.contains { $0.name == "Natter" },
            "phantom survived")
    }

    // MARK: - Stability gate (Step 8 — the actual fix)

    func testPromoteCountIfStable_noChangeWhenObservedMatchesCurrent() {
        let (newCount, newPending) = CacheMerge.promoteCountIfStable(
            observed: 6, current: 6, pending: nil
        )
        XCTAssertEqual(newCount, 6)
        XCTAssertNil(newPending)
    }

    func testPromoteCountIfStable_clearsPendingOnReturnToCurrent() {
        // We had a pending 12 but now observe 6 (back to current) — pending
        // should clear without promoting.
        let (newCount, newPending) = CacheMerge.promoteCountIfStable(
            observed: 6, current: 6, pending: 12
        )
        XCTAssertEqual(newCount, 6)
        XCTAssertNil(newPending)
    }

    func testPromoteCountIfStable_recordsFirstDifferentObservationAsPending() {
        // First time we see a different value — record as pending, hold
        // current. This is the gate that stopped the 6→9 bug.
        let (newCount, newPending) = CacheMerge.promoteCountIfStable(
            observed: 12, current: 6, pending: nil
        )
        XCTAssertEqual(newCount, 6, "must not adopt first transient reading")
        XCTAssertEqual(newPending, 12)
    }

    func testPromoteCountIfStable_promotesOnConfirmedReading() {
        // Second matching observation — confirmed, promote.
        let (newCount, newPending) = CacheMerge.promoteCountIfStable(
            observed: 7, current: 6, pending: 7
        )
        XCTAssertEqual(newCount, 7)
        XCTAssertNil(newPending)
    }

    func testPromoteCountIfStable_rebasesPendingOnDifferentObservation() {
        // Pending was 12; now we see 15 (another different value). Replace
        // pending with 15; don't promote either.
        let (newCount, newPending) = CacheMerge.promoteCountIfStable(
            observed: 15, current: 6, pending: 12
        )
        XCTAssertEqual(newCount, 6)
        XCTAssertEqual(newPending, 15)
    }

    /// End-to-end proof of the bug fix: the exact 6 → 12 → 6 sequence that
    /// produced the production 6→9 failure no longer inflates `current`.
    func testPromoteCountIfStable_protectsAgainst6to12to6Transient() {
        // Tick 1: see 12 (first time). Hold 6, pending=12.
        var result = CacheMerge.promoteCountIfStable(
            observed: 12, current: 6, pending: nil
        )
        XCTAssertEqual(result.newCount, 6)
        XCTAssertEqual(result.newPending, 12)

        // Tick 2: transient gone, see 6. Current=6, pending cleared.
        result = CacheMerge.promoteCountIfStable(
            observed: 6, current: result.newCount, pending: result.newPending
        )
        XCTAssertEqual(result.newCount, 6)
        XCTAssertNil(result.newPending)
    }

    /// Counter-test to the above: if 12 shows up TWICE in a row (a real,
    /// sustained state change — say the user genuinely added items while
    /// Snug was asleep), the gate promotes correctly.
    func testPromoteCountIfStable_promotesSustainedChange() {
        var result = CacheMerge.promoteCountIfStable(
            observed: 12, current: 6, pending: nil
        )
        XCTAssertEqual(result.newCount, 6, "first reading: no promote")

        result = CacheMerge.promoteCountIfStable(
            observed: 12, current: result.newCount, pending: result.newPending
        )
        XCTAssertEqual(result.newCount, 12, "second reading: promoted")
        XCTAssertNil(result.newPending)
    }

    /// Counter-test: once `postCollapseItemCount` returns to reality (via a
    /// follow-up postCollapseDiscovery), the trim step correctly drops
    /// phantoms. This proves the self-correction path works, and isolates
    /// the bug to the *refresh* path above.
    func testPostCollapseDiscovery_trimsPhantomsWhenCountSettles() {
        // Start from inflated state (as if left over from a previous
        // transient scan).
        let inflated = sixRealItems() + threePhantoms()

        let (settled, settledCount) = CacheMerge.applyPostCollapseDiscovery(
            cache: inflated,
            allPushedCount: 6,  // transient ended, reality returns
            newItemsByProcess: [],
            perAppResolved: [],
            isAppRunning: allRunning
        )

        XCTAssertEqual(settled.count, 6,
            "Trim fires when cache exceeds allPushedCount.")
        XCTAssertEqual(settledCount, 6)
        XCTAssertFalse(settled.contains { $0.name == "Folder Peek" },
            "phantom trimmed (lowest-confidence: windowID==0).")
        XCTAssertFalse(settled.contains { $0.name == "Macs Fan Control" },
            "phantom trimmed.")
        XCTAssertFalse(settled.contains { $0.name == "Natter" },
            "phantom trimmed.")
        // All 6 real items survive.
        XCTAssertEqual(Set(settled.map(\.name)), Set(sixRealItems().map(\.name)))
    }
}
