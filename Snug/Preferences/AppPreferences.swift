import Foundation

@MainActor
@Observable
final class AppPreferences {
    static let shared = AppPreferences()

    /// Callback for AppKit code that needs to react to preference changes.
    /// Single-subscriber by design — StatusBarController owns this slot.
    /// Assigning here silently displaces any previous observer; if a second
    /// subscriber is ever needed, replace this with NotificationCenter or a
    /// callback list.
    var onPreferencesChanged: (() -> Void)?

    var isAutoHide: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.isAutoHide) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.isAutoHide)
            onPreferencesChanged?()
        }
    }

    var autoHideInterval: AutoHideInterval {
        get {
            AutoHideInterval(rawValue: UserDefaults.standard.integer(forKey: Keys.autoHideInterval)) ?? .tenSeconds
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.autoHideInterval)
            onPreferencesChanged?()
        }
    }

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasCompletedOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    private init() {}

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.isAutoHide: false,
            Keys.autoHideInterval: AutoHideInterval.tenSeconds.rawValue,
            Keys.hasCompletedOnboarding: false,
        ])
    }

    enum Keys {
        static let isAutoHide = "isAutoHide"
        static let autoHideInterval = "numberOfSecondForAutoHide"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }
}
