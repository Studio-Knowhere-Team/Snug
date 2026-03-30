import AppKit
import SwiftUI

@MainActor
enum OnboardingWindow {
    private static var windowController: NSWindowController?

    static func show() {
        if let wc = windowController {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView {
            close()
        }

        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Snug"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 360))
        window.center()

        let wc = NSWindowController(window: window)
        windowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        windowController?.close()
        windowController = nil
    }
}
