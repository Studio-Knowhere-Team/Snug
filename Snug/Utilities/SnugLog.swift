import Foundation

/// Debug logger for Snug.
/// Only active in DEBUG builds; compiles to a no-op in release.
///
/// Usage: `snugLog("message with %@ format", someArg)`
///
/// In debug builds, logs are written to /tmp/snug-debug.log
/// Read logs:  `tail -f /tmp/snug-debug.log`
/// Clear logs: `> /tmp/snug-debug.log`

#if DEBUG
private let logFileURL: URL = {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snug-debug.log")
    return url
}()
private let logQueue = DispatchQueue(label: "com.snug.log", qos: .utility)
private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func snugLog(_ message: String, _ args: CVarArg...) {
    let formatted = args.isEmpty ? message : String(format: message, arguments: args)
    let timestamp = dateFormatter.string(from: Date())
    let line = "[\(timestamp)] \(formatted)\n"

    NSLog("[Snug] %@", formatted)

    logQueue.async {
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
                // Restrict log file to owner-only (contains app names, PIDs, bundle IDs)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
            }
        }
    }
}
#else
@inline(__always)
func snugLog(_ message: String, _ args: CVarArg...) {
    // No-op in release builds
}
#endif
