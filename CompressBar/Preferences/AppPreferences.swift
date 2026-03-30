import Foundation

@MainActor
@Observable
final class AppPreferences {
    static let shared = AppPreferences()

    /// Callback for AppKit code that needs to react to preference changes
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

    var isShowPreference: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.isShowPreference) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.isShowPreference) }
    }

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.hasCompletedOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    var globalKeybind: GlobalKeybindPreferences? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Keys.globalKey) else { return nil }
            return try? JSONDecoder().decode(GlobalKeybindPreferences.self, from: data)
        }
        set {
            if let newValue {
                let data = try? JSONEncoder().encode(newValue)
                UserDefaults.standard.set(data, forKey: Keys.globalKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.globalKey)
            }
            onPreferencesChanged?()
        }
    }

    private init() {}

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.isAutoHide: false,
            Keys.autoHideInterval: AutoHideInterval.tenSeconds.rawValue,
            Keys.isShowPreference: true,
            Keys.hasCompletedOnboarding: false,
        ])
    }

    enum Keys {
        static let isAutoHide = "isAutoHide"
        static let autoHideInterval = "numberOfSecondForAutoHide"
        static let isShowPreference = "isShowPreference"
        static let globalKey = "globalKey"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }
}
