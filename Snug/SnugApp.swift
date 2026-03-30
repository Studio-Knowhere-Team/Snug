import AppKit

@main
@MainActor
enum SnugApp {
    // Strong reference to prevent deallocation (NSApp.delegate is weak)
    static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}
