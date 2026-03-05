import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @State private var preferences = AppPreferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isRecordingShortcut = false
    @State private var shortcutMonitor: Any?
    @State private var accessibilityGranted = AccessibilityMenuBarHelper.isGranted
    @State private var accessibilityTimer: Timer?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            Section("Auto-collapse") {
                Toggle("Automatically collapse hidden section", isOn: Binding(
                    get: { preferences.isAutoHide },
                    set: { preferences.isAutoHide = $0 }
                ))

                if preferences.isAutoHide {
                    Picker("Collapse after", selection: Binding(
                        get: { preferences.autoHideInterval },
                        set: { preferences.autoHideInterval = $0 }
                    )) {
                        ForEach(AutoHideInterval.allCases, id: \.self) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Hold \u{2318} (Cmd) and drag menu bar icons to the left of the open circle.")
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                    }

                    Label {
                        Text("Click the icon to toggle \u{2014} the circle splits open or closes shut.")
                    } icon: {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(.secondary)
                    }

                    Label {
                        Text("When closed, the filled circle shows the count of hidden items.")
                    } icon: {
                        Image(systemName: "number")
                            .foregroundStyle(.secondary)
                    }

            
                }
                .font(.callout)
                .padding(.vertical, 4)
            } header: {
                Text("How to Use")
            }

            Section {
                HStack {
                    if accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Granted", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !accessibilityGranted {
                        Button("Open System Settings") {
                            AccessibilityMenuBarHelper.openAccessibilitySettings()
                        }
                    }
                }

                if !accessibilityGranted {
                    Text("Enable Accessibility access for Snug in System Settings \u{2192} Privacy & Security \u{2192} Accessibility.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Enables showing names of hidden menu bar items when right-clicking the toggle.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Accessibility")
            }

            Section("Keyboard Shortcut") {
                HStack {
                    if isRecordingShortcut {
                        Text("Press a key combination...")
                            .foregroundStyle(.secondary)
                    } else if let keybind = preferences.globalKeybind {
                        Text(keybind.description)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isRecordingShortcut {
                        Button("Cancel") {
                            stopRecording()
                        }
                    } else {
                        Button("Record Shortcut") {
                            startRecording()
                        }

                        if preferences.globalKeybind != nil {
                            Button("Clear") {
                                preferences.globalKeybind = nil
                                notifyHotKeyChanged()
                            }
                        }
                    }
                }
            }

        }
        .formStyle(.grouped)
        .onAppear {
            accessibilityGranted = AccessibilityMenuBarHelper.isGranted
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in
                    accessibilityGranted = AccessibilityMenuBarHelper.isGranted
                }
            }
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
        }
    }

    // MARK: - Launch at Login

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Shortcut Recording

    private func startRecording() {
        isRecordingShortcut = true
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Require at least one modifier key (not just a bare key)
            guard !modifiers.isEmpty else {
                if event.keyCode == 53 { // Escape
                    stopRecording()
                }
                return nil
            }

            let keybind = GlobalKeybindPreferences(
                function: modifiers.contains(.function),
                control: modifiers.contains(.control),
                command: modifiers.contains(.command),
                shift: modifiers.contains(.shift),
                option: modifiers.contains(.option),
                capsLock: modifiers.contains(.capsLock),
                carbonFlags: UInt32(modifiers.rawValue),
                characters: event.charactersIgnoringModifiers ?? "",
                keyCode: UInt32(event.keyCode)
            )

            preferences.globalKeybind = keybind
            stopRecording()
            notifyHotKeyChanged()
            return nil
        }
    }

    private func stopRecording() {
        isRecordingShortcut = false
        if let monitor = shortcutMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutMonitor = nil
        }
    }

    private func notifyHotKeyChanged() {
        NotificationCenter.default.post(name: Notification.Name("Snug.hotkeyChanged"), object: nil)
    }
}
