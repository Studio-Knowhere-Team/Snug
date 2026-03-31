import SwiftUI
import ServiceManagement
import Sparkle

struct GeneralSettingsView: View {
    @State private var preferences = AppPreferences.shared
    @State private var updaterController = UpdaterController.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
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

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updaterController.updater.automaticallyChecksForUpdates },
                    set: { updaterController.updater.automaticallyChecksForUpdates = $0 }
                ))
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
                Toggle("Show Pocket below notch", isOn: Binding(
                    get: { preferences.isPocketEnabled },
                    set: { preferences.isPocketEnabled = $0 }
                ))

                Text("When collapsed, hover over the notch to reveal hidden icons in a dropdown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pocket")
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
                        Text("Click the icon to toggle and the circle splits open or closes shut.")
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
            snugLog("toggleLaunchAtLogin failed: %@", error.localizedDescription)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

}
