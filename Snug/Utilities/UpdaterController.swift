import Foundation
import Sparkle
import Combine

/// Thin wrapper around Sparkle's SPUStandardUpdaterController.
/// Exposes update state as @Observable properties for SwiftUI consumption.
@MainActor
@Observable
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    /// The underlying updater — used for binding to `automaticallyChecksForUpdates`.
    var updater: SPUUpdater { controller.updater }

    /// Whether a manual "Check for Updates" action is currently possible.
    var canCheckForUpdates: Bool = false

    private var cancellable: AnyCancellable?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        canCheckForUpdates = updater.canCheckForUpdates

        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    /// Trigger a manual update check (shows UI to the user).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
