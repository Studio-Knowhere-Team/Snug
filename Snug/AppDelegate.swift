import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.registerDefaults()

        statusBarController = StatusBarController()

        // Show onboarding on first launch (handles AX permission request)
        if !AppPreferences.shared.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OnboardingWindow.show()
            }
        }

        // Start Sparkle's update cycle after setup is complete
        _ = UpdaterController.shared
    }

}
