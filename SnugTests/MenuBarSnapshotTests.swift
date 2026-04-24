import XCTest
import AppKit
@testable import Snug

/// Pins down the contract for `MenuBarSnapshot` independent of the live
/// controller. These tests run against the value type only — they do not
/// exercise StatusBarController, CGWindowList, or AX. Step 2+ of the
/// refactor will add tests that drive the synthesize path.
final class MenuBarSnapshotTests: XCTestCase {

    func testEmpty_hasSaneDefaults() {
        let s = MenuBarSnapshot.empty
        XCTAssertEqual(s.items.count, 0)
        XCTAssertEqual(s.totalCount, 0)
        XCTAssertTrue(s.naturalPositions.isEmpty)
        XCTAssertTrue(s.resolvedNames.isEmpty)
        XCTAssertEqual(s.capturedWidth, .unknown)
    }

    func testStableKey_hashesByPID() {
        let a1 = MenuBarSnapshot.StableKey(ownerPID: 42)
        let a2 = MenuBarSnapshot.StableKey(ownerPID: 42)
        let b  = MenuBarSnapshot.StableKey(ownerPID: 43)
        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, b)
        XCTAssertEqual(a1.hashValue, a2.hashValue)
    }

    /// Type must be `Sendable` so future steps can move discovery off the
    /// main actor without breaking the API. This is a compile-time check
    /// disguised as a runtime test.
    func testSnapshot_isSendable() {
        let s = MenuBarSnapshot.empty
        let task = Task.detached { () -> Int in
            // If `MenuBarSnapshot` were not Sendable, capturing `s` in this
            // closure would be a compile error under strict concurrency.
            return s.totalCount
        }
        let expectation = XCTestExpectation(description: "sendable")
        Task {
            _ = await task.value
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    /// Documents the invariant that motivated the whole type: a snapshot
    /// can know a `totalCount` larger than `items.count` (e.g. CGWindowList
    /// saw 6 pushed items but AX only resolved names for 4 of them). This
    /// test simply asserts the type allows that configuration — so the
    /// refactor can rely on it once writers start using it.
    func testSnapshot_allowsTotalCountGreaterThanItemsCount() {
        let snap = MenuBarSnapshot(
            items: [
                HiddenItemInfo(name: "A", icon: nil, frame: .zero, windowID: 1, ownerPID: 100),
                HiddenItemInfo(name: "B", icon: nil, frame: .zero, windowID: 2, ownerPID: 101),
            ],
            totalCount: 6,
            naturalPositions: [:],
            resolvedNames: [:],
            capturedAt: Date(),
            capturedWidth: .collapsed
        )
        XCTAssertGreaterThan(snap.totalCount, snap.items.count)
    }
}
