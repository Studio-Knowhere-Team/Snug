import Foundation

/// File-based debug logger for Snug.
/// Writes to /tmp/snug-debug.log so output is readable from Terminal
/// even when the app is launched from Xcode.
///
/// Usage: `snugLog("message with %@ format", someArg)`
///
/// Read logs:  `tail -f /tmp/snug-debug.log`
/// Clear logs: `> /tmp/snug-debug.log`

private let logFileURL = URL(fileURLWithPath: "/tmp/snug-debug.log")
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

    // Also send to NSLog so it appears in Xcode console
    NSLog("[Snug] %@", formatted)

    // Write to file on a background queue to avoid blocking main thread
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
            }
        }
    }
}
