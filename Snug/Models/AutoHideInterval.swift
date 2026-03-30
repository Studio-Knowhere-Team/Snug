import Foundation

/// Raw values skip 2 (previously used by a removed 15-second option).
/// Existing UserDefaults are preserved since raw values didn't change.
enum AutoHideInterval: Int, CaseIterable, Sendable {
    case fiveSeconds = 0
    case tenSeconds = 1
    // raw value 2 was fifteenSeconds (removed)
    case thirtySeconds = 3
    case oneMinute = 4

    var seconds: TimeInterval {
        switch self {
        case .fiveSeconds: 5
        case .tenSeconds: 10
        case .thirtySeconds: 30
        case .oneMinute: 60
        }
    }

    var displayName: String {
        switch self {
        case .fiveSeconds: "5 seconds"
        case .tenSeconds: "10 seconds"
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        }
    }
}
