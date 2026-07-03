import XCTest
import AppKit
@testable import Snug

/// Pins down the contract for `MenuBarSnapshot` independent of the live
/// controller. These tests run against the value type only — they do not
/// exercise StatusBarController, CGWindowList, or AX.
final class MenuBarSnapshotTests: XCTestCase {

    func testEmpty_hasSaneDefaults() {
        let s = MenuBarSnapshot.empty
        XCTAssertEqual(s.items.count, 0)
        XCTAssertEqual(s.totalCount, 0)
        XCTAssertEqual(s.capturedWidth, .unknown)
    }

    /// Type must be `Sendable` so discovery results can cross actor
    /// boundaries. This is a compile-time check disguised as a runtime test.
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
    /// saw 6 pushed items but AX only resolved names for 4 of them). The
    /// badge shows `totalCount`; the right-click menu shows `items`.
    func testSnapshot_allowsTotalCountGreaterThanItemsCount() {
        let snap = MenuBarSnapshot(
            items: [
                HiddenItemInfo(name: "A", icon: nil, frame: .zero, windowID: 1, ownerPID: 100),
                HiddenItemInfo(name: "B", icon: nil, frame: .zero, windowID: 2, ownerPID: 101),
            ],
            totalCount: 6,
            capturedAt: Date(),
            capturedWidth: .collapsed
        )
        XCTAssertGreaterThan(snap.totalCount, snap.items.count)
    }
}
