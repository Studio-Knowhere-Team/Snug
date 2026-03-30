import AppKit
import HotKey

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.registerDefaults()

        _ = UpdaterController.shared // Start Sparkle's update cycle

        statusBarController = StatusBarController()

        setupHotKey()

        // Show onboarding on first launch (handles AX permission request)
        if !AppPreferences.shared.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OnboardingWindow.show()
            }
        }

        // Listen for hotkey changes from the Settings UI
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: Notification.Name("Snug.hotkeyChanged"),
            object: nil
        )
    }

    @objc private func hotkeyDidChange() {
        setupHotKey()
    }

    // MARK: - HotKey

    func setupHotKey() {
        let prefs = AppPreferences.shared
        guard let keybind = prefs.globalKeybind else {
            hotKey = nil
            return
        }

        guard let key = Key(carbonKeyCode: keybind.keyCode) else {
            hotKey = nil
            return
        }

        var modifiers: NSEvent.ModifierFlags = []
        if keybind.control { modifiers.insert(.control) }
        if keybind.option { modifiers.insert(.option) }
        if keybind.command { modifiers.insert(.command) }
        if keybind.shift { modifiers.insert(.shift) }

        hotKey = HotKey(key: key, modifiers: modifiers)
        hotKey?.keyDownHandler = { [weak self] in
            self?.statusBarController.expandCollapseIfNeeded()
        }
    }

}
