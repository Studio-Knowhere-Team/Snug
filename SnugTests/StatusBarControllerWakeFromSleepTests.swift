import AppKit
import XCTest
@testable import Snug

@MainActor
final class StatusBarControllerWakeFromSleepTests: XCTestCase {
    private let logFileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snug-debug.log")

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        AppPreferences.registerDefaults()
        AppPreferences.shared.isPocketEnabled = false
        AppPreferences.shared.isAutoHide = false
        try? FileManager.default.removeItem(at: logFileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: logFileURL)
        try await super.tearDown()
    }

    func testHandleWakeFromSleepExpandsClearsCachesThenRecollapses() async throws {
        let controller = StatusBarController(scheduleInitialSetupWork: false)
        controller.debugSetCollapsedState(true, separatorLength: 240)
        controller.debugPrimeCaches()

        controller.debugInvokeWakeHandler()

        try await wait(for: 3.15)

        let expanded = controller.debugSnapshot()
        XCTAssertFalse(expanded.isCollapsed)
        XCTAssertEqual(expanded.separatorLength, NSStatusItem.variableLength)
        XCTAssertEqual(expanded.cachedNaturalPositionsCount, 0)
        XCTAssertEqual(expanded.cachedHiddenItemsCount, 0)
        XCTAssertEqual(expanded.cachedHiddenItemInfoCount, 0)
        XCTAssertFalse(expanded.startupRescanTimerIsActive)
        XCTAssertTrue(logContents().contains("handleWakeFromSleep: expanding"))

        try await wait(for: 0.8)

        let recollapsed = controller.debugSnapshot()
        XCTAssertTrue(recollapsed.isCollapsed)
        XCTAssertFalse(recollapsed.startupRescanTimerIsActive)
        XCTAssertTrue(logContents().contains("handleWakeFromSleep: re-collapsing with fresh AX data"))
    }

    func testHandleWakeFromSleepIsNoOpWhenMenuBarAlreadyExpanded() async throws {
        let controller = StatusBarController(scheduleInitialSetupWork: false)
        controller.debugSetCollapsedState(false, separatorLength: NSStatusItem.variableLength)
        controller.debugPrimeCaches()

        let before = controller.debugSnapshot()
        controller.debugInvokeWakeHandler()

        try await wait(for: 3.7)

        let after = controller.debugSnapshot()
        XCTAssertEqual(after.isCollapsed, before.isCollapsed)
        XCTAssertEqual(after.separatorLength, before.separatorLength)
        XCTAssertEqual(after.cachedNaturalPositionsCount, before.cachedNaturalPositionsCount)
        XCTAssertEqual(after.cachedHiddenItemsCount, before.cachedHiddenItemsCount)
        XCTAssertEqual(after.cachedHiddenItemInfoCount, before.cachedHiddenItemInfoCount)
        XCTAssertFalse(after.startupRescanTimerIsActive)
        XCTAssertFalse(logContents().contains("handleWakeFromSleep: expanding"))
        XCTAssertFalse(logContents().contains("handleWakeFromSleep: re-collapsing with fresh AX data"))
    }

    func testHandleWakeFromSleepSkipsDelayedRefreshIfUserExpandsBeforeStabilization() async throws {
        let controller = StatusBarController(scheduleInitialSetupWork: false)
        controller.debugSetCollapsedState(true, separatorLength: 240)
        controller.debugPrimeCaches()

        controller.debugInvokeWakeHandler()

        try await wait(for: 1.0)
        controller.debugSetCollapsedState(false, separatorLength: NSStatusItem.variableLength)

        try await wait(for: 2.8)

        let snapshot = controller.debugSnapshot()
        XCTAssertFalse(snapshot.isCollapsed)
        XCTAssertEqual(snapshot.separatorLength, NSStatusItem.variableLength)
        XCTAssertEqual(snapshot.cachedNaturalPositionsCount, 1)
        XCTAssertEqual(snapshot.cachedHiddenItemsCount, 1)
        XCTAssertEqual(snapshot.cachedHiddenItemInfoCount, 1)
        XCTAssertFalse(snapshot.startupRescanTimerIsActive)
        XCTAssertFalse(logContents().contains("handleWakeFromSleep: expanding"))
        XCTAssertFalse(logContents().contains("handleWakeFromSleep: re-collapsing with fresh AX data"))
    }

    private func wait(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func logContents() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }
}
