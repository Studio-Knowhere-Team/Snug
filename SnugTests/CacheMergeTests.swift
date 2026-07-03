import XCTest
import AppKit
@testable import Snug

/// Exercises `CacheMerge` with fixtures modeled on the 6→9 phantom inflation
/// observed in production logs on 2026-04-24: a transient `allPushedCount`
/// (CGWindowList briefly duplicating items during a display reconfig) must
/// never become the authoritative count, so per-app phantoms never find a
/// gap to fill and never survive an expand refresh.
///
/// These are the same pure functions the live controller calls from
/// `postCollapseDiscovery` / `refreshHiddenItemCache` — the tests exercise
/// shipping code, not a parallel copy.
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

    // MARK: - Name helpers

    func testBaseName_stripsCountSuffix() {
        XCTAssertEqual(CacheMerge.baseName(of: "Dropbox"), "Dropbox")
        XCTAssertEqual(CacheMerge.baseName(of: "Dropbox (2)"), "Dropbox")
        XCTAssertEqual(CacheMerge.baseName(of: "App (12)"), "App")
        XCTAssertEqual(CacheMerge.baseName(of: "App (1.5)"), "App (1.5)")  // non-integer: not stripped
    }

    func testIsControlCentre_matchesBothSpellings() {
        XCTAssertTrue(CacheMerge.isControlCentre("Control Centre"))
        XCTAssertTrue(CacheMerge.isControlCentre("Control Center"))
        XCTAssertFalse(CacheMerge.isControlCentre("Control"))
        XCTAssertFalse(CacheMerge.isControlCentre("Dropbox"))
    }

    func testDedupeByName_singleEntriesPassThroughSorted() {
        let result = CacheMerge.dedupeByName([
            info("Zoom", pid: 2, wid: 20),
            info("Alfred", pid: 1, wid: 10),
        ])
        XCTAssertEqual(result.map(\.name), ["Alfred", "Zoom"])
    }

    func testDedupeByName_duplicatesGetCountSuffix_keepingFirstEntry() {
        let result = CacheMerge.dedupeByName([
            info("Dropbox", pid: 5, wid: 50),
            info("Dropbox", pid: 5, wid: 51),
            info("Alfred", pid: 1, wid: 10),
        ])
        XCTAssertEqual(result.map(\.name), ["Alfred", "Dropbox (2)"])
        // First-seen entry wins for metadata.
        XCTAssertEqual(result.last?.windowID, 50)
    }

    // MARK: - Post-collapse reconciliation

    func testStableState_postCollapseDoesNothing() {
        let cache = sixRealItems()
        let next = CacheMerge.applyPostCollapseDiscovery(
            cache: cache,
            stableCount: 6,
            newItemsByProcess: [],
            perAppResolved: [],
            isAppRunning: allRunning
        )
        XCTAssertEqual(next.map(\.name), cache.map(\.name))
    }

    func testQuitApp_isPruned() {
        let cache = sixRealItems()
        let runningExceptFlux: (pid_t) -> Bool = { $0 != 5780 }
        let next = CacheMerge.applyPostCollapseDiscovery(
            cache: cache,
            stableCount: 5,
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

        let next = CacheMerge.applyPostCollapseDiscovery(
            cache: cache,
            stableCount: 6,
            newItemsByProcess: fourReal,
            perAppResolved: allSix,
            isAppRunning: allRunning
        )
        XCTAssertEqual(next.count, 6)
        XCTAssertEqual(Set(next.map(\.name)), Set(sixRealItems().map(\.name)))
    }

    // MARK: - Phantom rejection (the 6→9 fix)

    /// The first half of the 6→9 scenario, with the fix in place: a display
    /// glitch makes CGWindowList briefly report 12 items and the per-app
    /// scan surface 3 phantoms — but the stability gate holds the stable
    /// count at 6, so the phantoms find no gap and are rejected.
    func testTransientInflation_doesNotAdmitPhantoms() {
        let next = CacheMerge.applyPostCollapseDiscovery(
            cache: sixRealItems(),
            stableCount: 6,  // gate held the transient 12 as pending
            newItemsByProcess: [],
            perAppResolved: sixRealItems() + threePhantoms(),
            isAppRunning: allRunning
        )
        XCTAssertEqual(next.count, 6, "no gap under the stable count → no phantoms")
        XCTAssertFalse(next.contains { $0.name == "Folder Peek" })
        XCTAssertFalse(next.contains { $0.name == "Macs Fan Control" })
        XCTAssertFalse(next.contains { $0.name == "Natter" })
    }

    /// End-to-end sequence of the production 6→9 failure, with the fix:
    ///  (1) transient observation of 12 is held as pending, not promoted;
    ///  (2) discovery reconciles against the stable count of 6 → phantoms
    ///      rejected;
    ///  (3) the transient clears (observe 6 again) → pending dropped;
    ///  (4) expand refresh caps at 6 → cache stays at the 6 real items.
    func testTransientSequence_endToEnd_staysAtSix() {
        // Tick 1: observe transient 12 → hold current 6, pending 12.
        let gate1 = CacheMerge.promoteCountIfStable(observed: 12, current: 6, pending: nil)
        XCTAssertEqual(gate1.newCount, 6)
        XCTAssertEqual(gate1.newPending, 12)

        // Discovery runs with the STABLE count — phantoms rejected.
        let cache1 = CacheMerge.applyPostCollapseDiscovery(
            cache: sixRealItems(),
            stableCount: gate1.newCount,
            newItemsByProcess: [],
            perAppResolved: sixRealItems() + threePhantoms(),
            isAppRunning: allRunning
        )
        XCTAssertEqual(cache1.count, 6)

        // Tick 2: transient gone, observe 6 → pending cleared.
        let gate2 = CacheMerge.promoteCountIfStable(
            observed: 6, current: gate1.newCount, pending: gate1.newPending
        )
        XCTAssertEqual(gate2.newCount, 6)
        XCTAssertNil(gate2.newPending)

        // User expands. Refresh caps at 6 — nothing phantom to preserve.
        let refreshed = CacheMerge.applyRefreshAfterExpand(
            cache: cache1,
            freshInfo: sixRealItems(),
            hiddenCount: 6,
            postCollapseItemCount: gate2.newCount,
            isAppRunning: allRunning
        )
        XCTAssertEqual(refreshed.count, 6)
        XCTAssertEqual(Set(refreshed.map(\.name)), Set(sixRealItems().map(\.name)))
    }

    /// Quit-app entries must not survive an expand refresh via the
    /// preserved-entries path. This covers the window where the user
    /// expands while postCollapseDiscovery's per-app scan is in flight:
    /// that scan's merge (including its quit-app prune) is discarded, so
    /// the expand refresh is the only reconciliation until the next
    /// collapse.
    func testRefreshAfterExpand_prunesQuitAppFromPreserved() {
        let cache = sixRealItems()
        // Flux (pid 5780) quit while hidden; fresh AX resolves the other 5.
        let fresh = cache.filter { $0.ownerPID != 5780 }
        let runningExceptFlux: (pid_t) -> Bool = { $0 != 5780 }

        let refreshed = CacheMerge.applyRefreshAfterExpand(
            cache: cache,
            freshInfo: fresh,
            hiddenCount: 5,
            postCollapseItemCount: 6,  // stale: gate hasn't seen the quit yet
            isAppRunning: runningExceptFlux
        )

        XCTAssertEqual(refreshed.count, 5)
        XCTAssertFalse(refreshed.contains { $0.ownerPID == 5780 },
            "quit app pruned even though the stale count left it a slot")
    }

    /// Self-correction path: if phantoms somehow made it into the cache
    /// (e.g. state left over from a version without the gate), the trim
    /// step drops them once the stable count reflects reality — and drops
    /// the low-confidence `windowID == 0` entries first.
    func testPostCollapseDiscovery_trimsPhantomsWhenCountSettles() {
        let inflated = sixRealItems() + threePhantoms()

        let settled = CacheMerge.applyPostCollapseDiscovery(
            cache: inflated,
            stableCount: 6,  // transient ended, reality returns
            newItemsByProcess: [],
            perAppResolved: [],
            isAppRunning: allRunning
        )

        XCTAssertEqual(settled.count, 6,
            "Trim fires when cache exceeds the stable count.")
        XCTAssertFalse(settled.contains { $0.name == "Folder Peek" },
            "phantom trimmed (lowest-confidence: windowID==0).")
        XCTAssertFalse(settled.contains { $0.name == "Macs Fan Control" },
            "phantom trimmed.")
        XCTAssertFalse(settled.contains { $0.name == "Natter" },
            "phantom trimmed.")
        // All 6 real items survive.
        XCTAssertEqual(Set(settled.map(\.name)), Set(sixRealItems().map(\.name)))
    }

    // MARK: - Stability gate

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

    /// The exact 6 → 12 → 6 sequence that produced the production 6→9
    /// failure no longer inflates `current`.
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
}
